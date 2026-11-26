// Command Center (default page): StatusCards on top, chat list,
// composer at the bottom. Renders every ChatResponse kind.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/models.dart';
import 'app_state.dart';
import 'duplicates_page.dart';
import 'file_row.dart';
import 'folders_dialog.dart';
import 'organize_page.dart';
import 'screen_qa_flow.dart';

const String welcomeMessage =
    'Hi, I\'m DJ. I find your files on this laptop - by name or by what '
    'is inside them. Try "find my Virun pitch", "open the frontend folder", '
    '"summarize my Virun pitch", "organize yesterday\'s Downloads", '
    '"find duplicates", or "open notepad". Summaries are picked from the '
    'file itself, no AI.';

class _ChatEntry {
  _ChatEntry({required this.isUser, required this.text, this.response});

  final bool isUser;
  final String text;
  final ChatResponse? response;
}

class CommandPage extends StatefulWidget {
  const CommandPage({super.key, required this.app});

  final DjAppState app;

  @override
  State<CommandPage> createState() => _CommandPageState();
}

class _CommandPageState extends State<CommandPage> {
  final List<_ChatEntry> _messages = [
    _ChatEntry(isUser: false, text: welcomeMessage),
  ];
  final TextEditingController _composer = TextEditingController();
  final ScrollController _scroll = ScrollController();
  bool _busy = false;
  bool _listening = false;
  late int _seenBuildVersion;
  StreamSubscription<String>? _partialSub;
  StreamSubscription<String>? _finalSub;
  StreamSubscription<String>? _speechErrSub;

  @override
  void initState() {
    super.initState();
    _seenBuildVersion = widget.app.indexBuiltVersion.value;
    widget.app.indexBuiltVersion.addListener(_onIndexBuilt);
    _composer.addListener(() => setState(() {}));
    _partialSub = widget.app.voiceChannel.onPartialResult.listen((text) {
      if (!mounted || !_listening) return;
      _composer.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      unawaited(widget.app.updateCompanion('listening', text));
    });
    _finalSub = widget.app.voiceChannel.onFinalResult.listen((text) {
      if (!mounted || !_listening) return;
      _listening = false;
      final trimmed = text.trim();
      setState(() {});
      unawaited(widget.app.updateCompanion('idle'));
      if (trimmed.isNotEmpty) {
        _composer.text = trimmed;
        _send();
      }
    });
    _speechErrSub = widget.app.voiceChannel.onSpeechError.listen((err) {
      if (!mounted || !_listening) return;
      setState(() => _listening = false);
      unawaited(widget.app.updateCompanion('idle'));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Voice input: $err')),
      );
    });
  }

  @override
  void dispose() {
    _partialSub?.cancel();
    _finalSub?.cancel();
    _speechErrSub?.cancel();
    widget.app.indexBuiltVersion.removeListener(_onIndexBuilt);
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _toggleVoice() async {
    if (_busy) return;
    if (_listening) {
      await widget.app.voiceChannel.stopListening();
      if (!mounted) return;
      setState(() => _listening = false);
      await widget.app.updateCompanion('idle');
      return;
    }
    setState(() => _listening = true);
    await widget.app.updateCompanion('listening', 'Listening...');
    final res = await widget.app.voiceChannel.startListening();
    if (!mounted) return;
    if (res['ok'] != true) {
      setState(() => _listening = false);
      await widget.app.updateCompanion('idle');
      if (!mounted) return;
      final msg =
          (res['error'] ?? res['message'] ?? 'Voice unavailable').toString();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg)),
      );
    }
  }

  void _onIndexBuilt() {
    final version = widget.app.indexBuiltVersion.value;
    if (version <= _seenBuildVersion) return;
    _seenBuildVersion = version;
    final text = widget.app.lastIndexBuiltText;
    if (text == null || !mounted) return;
    setState(() => _messages.add(_ChatEntry(isUser: false, text: text)));
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  void _appendResponse(ChatResponse response) {
    setState(() =>
        _messages.add(_ChatEntry(isUser: false, text: response.text, response: response)));
    _scrollToBottom();
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty || _busy) return;
    _composer.clear();
    setState(() {
      _messages.add(_ChatEntry(isUser: true, text: text));
      _busy = true;
    });
    _scrollToBottom();
    ChatResponse response;
    try {
      response = await widget.app.chat.handle(text);
    } catch (e) {
      response = ChatResponseMessage(text: 'Something went wrong: $e');
    }
    if (!mounted) return;
    setState(() {
      _messages.add(
          _ChatEntry(isUser: false, text: response.text, response: response));
      _busy = false;
    });
    _scrollToBottom();
  }

  Future<void> _openFile(String path) async {
    final result = await widget.app.systemOps.openFile(path);
    if (!mounted) return;
    if (!result.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.message)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StatusCards(app: widget.app),
          const SizedBox(height: 12),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              itemCount: _messages.length + (_busy ? 1 : 0),
              itemBuilder: (context, i) {
                if (i >= _messages.length) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('DJ is working...'),
                  );
                }
                final entry = _messages[i];
                if (entry.isUser) {
                  return Align(
                    alignment: Alignment.centerRight,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        border: Border.all(
                            color: const Color(0xFFE5E5E5)),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(entry.text),
                    ),
                  );
                }
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: _ResponseBody(
                    response: entry.response,
                    text: entry.text,
                    app: widget.app,
                    onOpenFile: _openFile,
                    onAppend: _appendResponse,
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _composer,
                  onSubmitted: (_) => _send(),
                  decoration: const InputDecoration(
                    hintText:
                        'Find a file, open a folder, organize Downloads...',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (Platform.isAndroid) ...[
                IconButton(
                  tooltip: _listening ? 'Stop listening' : 'Speak command',
                  icon: Icon(_listening ? Icons.mic_off : Icons.mic),
                  color: _listening ? Theme.of(context).colorScheme.error : null,
                  onPressed: _busy ? null : _toggleVoice,
                ),
                const SizedBox(width: 4),
              ],
              IconButton(
                tooltip: 'Ask DJ about your screen',
                icon: const Icon(Icons.auto_awesome, size: 20),
                onPressed: _busy ? null : () => runScreenQaFlow(context, widget.app),
              ),
              const SizedBox(width: 4),
              ElevatedButton(
                onPressed: (_busy || _composer.text.trim().isEmpty)
                    ? null
                    : _send,
                child: const Text('Send'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusCards extends StatelessWidget {
  const _StatusCards({required this.app});

  final DjAppState app;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DjStatus?>(
      valueListenable: app.status,
      builder: (context, status, _) {
        final cap = status?.capability;
        final localName = cap?.local.name;
        return LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth > 640;
            final cards = <Widget>[
              _statusCard(
                context,
                title: 'Capability',
                width: wide ? (constraints.maxWidth - 32) / 3 : null,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      capabilityBadgeLabel(cap),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(cap?.message ?? 'Checking capability...'),
                  ],
                ),
              ),
              _statusCard(
                context,
                title: 'Index',
                width: wide ? (constraints.maxWidth - 32) / 3 : null,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      status == null
                          ? 'Loading index status...'
                          : '${status.filesIndexed} files in '
                              '${status.foldersIndexed} folders',
                    ),
                    const SizedBox(height: 4),
                    Text(searchModeLabel(status)),
                    Text(embedderLabel(status)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed: () => app.rebuildIndex(),
                          child: const Text('Rebuild index'),
                        ),
                        OutlinedButton(
                          onPressed: () => showFoldersDialog(
                            context,
                            app: app,
                            firstRun: false,
                          ),
                          child: const Text('Folders'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              _statusCard(
                context,
                title: 'Model',
                width: wide ? (constraints.maxWidth - 32) / 3 : null,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      cap != null && cap.local.available
                          ? 'Local model running: ${localName ?? 'unknown'}'
                          : 'Local model not running',
                    ),
                    const SizedBox(height: 4),
                    Text(cap == null
                        ? 'No cloud key set'
                        : cloudKeyLine(cap)),
                    const SizedBox(height: 4),
                    const Text(
                      'DJ works with no model and no key. '
                      'A model or key only adds better answers.',
                    ),
                  ],
                ),
              ),
            ];
            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < cards.length; i++) ...[
                    if (i > 0) const SizedBox(width: 16),
                    cards[i],
                  ],
                ],
              );
            }
            return Column(
              children: [
                for (var i = 0; i < cards.length; i++) ...[
                  if (i > 0) const SizedBox(height: 12),
                  cards[i],
                ],
              ],
            );
          },
        );
      },
    );
  }

  Widget _statusCard(
    BuildContext context, {
    required String title,
    required Widget child,
    double? width,
  }) {
    return SizedBox(
      width: width,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// Renders one DJ reply, by ChatResponse kind.
class _ResponseBody extends StatelessWidget {
  const _ResponseBody({
    required this.response,
    required this.text,
    required this.app,
    required this.onOpenFile,
    required this.onAppend,
  });

  final ChatResponse? response;
  final String text;
  final DjAppState app;
  final Future<void> Function(String path) onOpenFile;
  final void Function(ChatResponse response) onAppend;

  @override
  Widget build(BuildContext context) {
    final r = response;
    if (r == null) return Text(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text),
        const SizedBox(height: 4),
        switch (r) {
          ChatResponseSearch(:final results) ||
          ChatResponseOpened(:final results) =>
            Column(
              children: [
                for (final result in results)
                  FileRow(
                    result: result,
                    onOpen: () => onOpenFile(result.path),
                  ),
              ],
            ),
          ChatResponseSummary(:final fileName, :final summary, :final note) =>
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fileName,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(summary),
                const SizedBox(height: 4),
                Text(note),
              ],
            ),
          ChatResponseOrganizePlan(:final plan) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                OrganizePlanTable(plan: plan),
                const SizedBox(height: 12),
                Row(
                  children: [
                    ElevatedButton(
                      onPressed: () async {
                        final confirmed =
                            await showOrganizeConfirm(context, plan);
                        if (!confirmed) return;
                        onAppend(app.chat.applyOrganize(plan));
                      },
                      child: const Text('Yes, move them'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () => onAppend(const ChatResponseMessage(
                        text: 'Organize cancelled. Nothing was moved.',
                      )),
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ],
            ),
          ChatResponseOrganizeDone(:final errors, :final logPath) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final e in errors) Text(e),
                if (logPath.isNotEmpty) Text('Log: $logPath'),
              ],
            ),
          ChatResponseDuplicates(:final groups) =>
            _ChatDuplicates(app: app, groups: groups, onAppend: onAppend),
          ChatResponseDuplicatesDeleted(:final deleted, :final errors) =>
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final d in deleted) Text(d),
                for (final e in errors) Text(e),
              ],
            ),
          ChatResponseDuplicatesMerged(:final moved, :final errors) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final m in moved) Text(m),
                for (final e in errors) Text(e),
              ],
            ),
          ChatResponseAskRange() => Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (label, range) in organizeRanges)
                  OutlinedButton(
                    onPressed: () => onAppend(app.chat.planOrganize(range)),
                    child: Text(label),
                  ),
              ],
            ),
          ChatResponseHelp() => const SizedBox.shrink(),
          ChatResponseFolders(:final folders) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final folder in folders)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: OutlinedButton(
                      onPressed: () async {
                        final opened =
                            await app.systemOps.openFolder(folder.path);
                        onAppend(ChatResponseMessage(
                          text: opened.ok
                              ? 'Opened the ${folder.name} folder.'
                              : opened.message,
                        ));
                      },
                      child: Text('${folder.name} - ${folder.path}'),
                    ),
                  ),
              ],
            ),
          ChatResponseMessage() => const SizedBox.shrink(),
        },
      ],
    );
  }
}

/// Duplicate groups inside a chat reply, with per-group selection,
/// a Delete selected copies button, and a Merge button per group.
class _ChatDuplicates extends StatefulWidget {
  const _ChatDuplicates({
    required this.app,
    required this.groups,
    required this.onAppend,
  });

  final DjAppState app;
  final List<DuplicateGroup> groups;
  final void Function(ChatResponse response) onAppend;

  @override
  State<_ChatDuplicates> createState() => _ChatDuplicatesState();
}

class _ChatDuplicatesState extends State<_ChatDuplicates> {
  final Set<String> _selected = {};

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final paths = _selected.toList();
    final confirmed = await showDeleteConfirm(context, paths);
    if (!confirmed || !mounted) return;
    final result = await widget.app.chat.deleteDuplicates(paths);
    if (!mounted) return;
    final lines = <String>[];
    if (result.deleted.isNotEmpty) {
      lines.add(
          'Deleted ${result.deleted.length} copie(s) to the Recycle Bin.');
    }
    lines.addAll(result.errors);
    if (result.logPath.isNotEmpty) lines.add('Log: ${result.logPath}');
    widget.onAppend(ChatResponseDuplicatesDeleted(
      text: lines.join('\n'),
      deleted: result.deleted,
      errors: result.errors,
    ));
  }

  Future<void> _mergeGroup(DuplicateGroup group) async {
    final target =
        await showMergeTargetDialog(context, widget.app, group);
    if (target == null || !mounted) return;
    final paths = group.files.map((f) => f.path).toList();
    final result = widget.app.chat.mergeDuplicates(paths, target);
    if (!mounted) return;
    final lines = <String>[];
    if (result.moved.isNotEmpty) {
      lines.add('Moved ${result.moved.length} copie(s) into $target.');
    }
    lines.addAll(result.errors);
    widget.onAppend(ChatResponseDuplicatesMerged(
      text: lines.join('\n'),
      moved: result.moved,
      errors: result.errors,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final group in widget.groups)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: DuplicateGroupCard(
              group: group,
              selected: _selected,
              onToggle: (path, checked) {
                setState(() {
                  if (checked) {
                    _selected.add(path);
                  } else {
                    _selected.remove(path);
                  }
                });
              },
              onMerge: () => _mergeGroup(group),
            ),
          ),
        const SizedBox(height: 8),
        ElevatedButton(
          onPressed: _selected.isEmpty ? null : _deleteSelected,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFC81E1E),
          ),
          child: const Text('Delete selected copies'),
        ),
      ],
    );
  }
}
