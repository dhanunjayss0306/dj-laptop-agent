// Duplicates page. Loads on open, one card per group, keeper first
// with a "keep" badge and no checkbox, extra copies with Delete
// checkboxes. Delete goes to the Recycle Bin only, after a confirm
// dialog. Merge keeps the first copy where it is and moves the rest
// into one folder the user picks.
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/judge.dart';
import '../core/models.dart';
import 'app_state.dart';
import 'file_type.dart';

/// Confirm dialog for deleting duplicate copies. Shows the judge
/// warnings. Returns true when the user confirms.
Future<bool> showDeleteConfirm(
  BuildContext context,
  List<String> paths,
) async {
  final judged = judgeAction(JudgeInput(
    kind: 'delete',
    text: 'delete the extra copies',
    destructive: true,
    targetCount: paths.length,
  ));
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Delete these copies?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'These copies go to the Recycle Bin. The first copy is kept. '
            'Are you sure?',
          ),
          for (final w in judged.warnings) ...[
            const SizedBox(height: 8),
            Text('Note: $w'),
          ],
          for (final b in judged.blocked) ...[
            const SizedBox(height: 8),
            Text('Blocked: $b'),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: judged.blocked.isNotEmpty
              ? null
              : () => Navigator.of(context).pop(true),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFC81E1E),
          ),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// Merge target dialog. The default target is derived from the user's
/// home/Downloads/Merged folder, never a hardcoded username. Returns
/// the picked target, or null when cancelled.
Future<String?> showMergeTargetDialog(
  BuildContext context,
  DjAppState app,
  DuplicateGroup group,
) async {
  final sep = Platform.pathSeparator;
  final defaultTarget =
      '${app.downloadsDir}${sep}Merged';
  final controller = TextEditingController(text: defaultTarget);
  final target = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Merge into one folder'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'The first copy stays where it is. The other copies move '
            'into this folder. The folder is created if it does not exist. '
            'Check the path before confirming.',
          ),
          const SizedBox(height: 12),
          const Text('Target folder'),
          const SizedBox(height: 4),
          TextField(
            controller: controller,
            decoration: const InputDecoration(
              hintText: 'Target folder',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          child: const Text('Merge'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (target == null || target.isEmpty) return null;
  return target;
}

/// One duplicate group card. The keeper row has a "keep" badge and no
/// checkbox; every extra copy has a Delete checkbox.
class DuplicateGroupCard extends StatelessWidget {
  const DuplicateGroupCard({
    super.key,
    required this.group,
    required this.selected,
    required this.onToggle,
    this.onMerge,
  });

  final DuplicateGroup group;
  final Set<String> selected;
  final void Function(String path, bool checked) onToggle;
  final VoidCallback? onMerge;

  @override
  Widget build(BuildContext context) {
    final keeper = group.files.first;
    final extras = group.files.skip(1).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${keeper.name} - ${group.sizeText}, '
              '${group.files.length} copies, '
              '${formatBytes(group.wasted)} wasted',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            _fileRow(
              context,
              file: keeper,
              isKeeper: true,
              checked: false,
              onToggle: null,
            ),
            for (final file in extras)
              _fileRow(
                context,
                file: file,
                isKeeper: false,
                checked: selected.contains(file.path),
                onToggle: (checked) => onToggle(file.path, checked),
              ),
            if (onMerge != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton(
                  onPressed: onMerge,
                  child: const Text('Merge into one folder'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _fileRow(
    BuildContext context, {
    required DuplicateFile file,
    required bool isKeeper,
    required bool checked,
    required void Function(bool)? onToggle,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          if (!isKeeper)
            Checkbox(
              value: checked,
              onChanged: (v) => onToggle?.call(v ?? false),
            )
          else
            const SizedBox(width: 48),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        file.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (isKeeper)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          border: Border.all(
                              color: const Color(0xFFE5E5E5)),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'keep',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                  ],
                ),
                Text(
                  file.folder,
                  style: const TextStyle(fontSize: 12),
                ),
                if (file.mtime.isNotEmpty)
                  Text(
                    formatDate(file.mtime),
                    style: const TextStyle(fontSize: 12),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class DuplicatesPage extends StatefulWidget {
  const DuplicatesPage({super.key, required this.app});

  final DjAppState app;

  @override
  State<DuplicatesPage> createState() => _DuplicatesPageState();
}

class _DuplicatesPageState extends State<DuplicatesPage> {
  List<DuplicateGroup>? _groups;
  String? _error;
  final Set<String> _selected = {};
  String? _resultLine;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _groups = null;
      _error = null;
    });
    try {
      final groups = await widget.app.duplicates.find(
        widget.app.config.value.folders
            .where((f) => f.enabled)
            .map((f) => f.path)
            .toList(),
      );
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _selected.clear();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not find duplicates: $e');
    }
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final paths = _selected.toList();
    final confirmed = await showDeleteConfirm(context, paths);
    if (!confirmed || !mounted) return;
    final result =
        await widget.app.chat.deleteDuplicates(paths);
    if (!mounted) return;
    final lines = <String>[];
    if (result.deleted.isNotEmpty) {
      lines.add(
          'Deleted ${result.deleted.length} copie(s) to the Recycle Bin.');
    }
    lines.addAll(result.errors);
    if (result.logPath.isNotEmpty) lines.add('Log: ${result.logPath}');
    setState(() => _resultLine = lines.join('\n'));
    await _load();
  }

  Future<void> _mergeGroup(DuplicateGroup group) async {
    final target =
        await showMergeTargetDialog(context, widget.app, group);
    if (target == null || !mounted) return;
    final paths = group.files.map((f) => f.path).toList();
    final judged = judgeAction(JudgeInput(
      kind: 'merge',
      text: 'merge the extra copies into $target',
      destructive: true,
      targetCount: paths.length,
    ));
    if (judged.blocked.isNotEmpty) {
      setState(
          () => _resultLine = 'Merge blocked: ${judged.blocked.join(', ')}');
      return;
    }
    final result = widget.app.chat.mergeDuplicates(paths, target);
    if (!mounted) return;
    final lines = <String>[];
    if (result.moved.isNotEmpty) {
      lines.add('Moved ${result.moved.length} copie(s) into $target.');
    }
    lines.addAll(result.errors);
    setState(() => _resultLine = lines.join('\n'));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Duplicates',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
              ),
              OutlinedButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Find duplicates'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_resultLine != null) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_resultLine!),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (_error != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_error!),
              ),
            )
          else if (groups == null)
            const Expanded(child: _DuplicatesSkeleton())
          else if (groups.isEmpty)
            const Expanded(
              child: Center(
                child: Text('No duplicates found'),
              ),
            )
          else
            Expanded(
              child: Column(
                children: [
                  Expanded(
                    child: ListView.separated(
                      itemCount: groups.length,
                      separatorBuilder: (_, __) =>
                          const SizedBox(height: 12),
                      itemBuilder: (context, i) => DuplicateGroupCard(
                        group: groups[i],
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
                        onMerge: () => _mergeGroup(groups[i]),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _selected.isEmpty ? null : _deleteSelected,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFC81E1E),
                      ),
                      child: const Text('Delete selected copies'),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _DuplicatesSkeleton extends StatelessWidget {
  const _DuplicatesSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      itemCount: 3,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, _) => Container(
        height: 120,
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFFE5E5E5)),
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Padding(
          padding: EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 220,
                height: 14,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: Color(0xFFF5F5F7)),
                ),
              ),
              SizedBox(height: 12),
              SizedBox(
                width: 160,
                height: 12,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: Color(0xFFF5F5F7)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
