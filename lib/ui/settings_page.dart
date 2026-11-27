// Settings page: 4 cards (Folders, Capability, Always running, About DJ)
// plus a small optional Cloud section. The Cloud section is new UI:
// keys live in the Cloudflare Worker, never in the app.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/local_model.dart';
import '../core/models.dart';
import '../platform/auto_updater.dart';
import '../platform/update_note.dart';
import 'app_state.dart';
import 'folders_dialog.dart';
import 'screen_qa_flow.dart';
import 'sign_in_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.app});

  final DjAppState app;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _workerUrl;
  late String _provider;
  late final TextEditingController _model;
  late final TextEditingController _sharedKey;
  bool _cloudSaved = false;

  late String _localKind;
  late final TextEditingController _localModel;
  late bool _preferLocal;
  bool _localSaved = false;
  bool _localChecking = false;
  String _localStatus = '';
  List<String> _localFound = [];

  @override
  void initState() {
    super.initState();
    final cloud = widget.app.loadCloudSettings();
    _workerUrl = TextEditingController(text: cloud.workerUrl);
    _provider = cloud.provider;
    _model = TextEditingController(
      text: DjAppState.effectiveCloudModel(cloud),
    );
    _sharedKey = TextEditingController(text: cloud.sharedKey);
    final picked = widget.app.config.value.localModel;
    _localKind = picked?.kind == 'lmstudio' ? 'lmstudio' : 'ollama';
    _localModel = TextEditingController(text: picked?.model ?? '');
    _preferLocal = widget.app.config.value.preferLocal ?? false;
  }

  @override
  void dispose() {
    _workerUrl.dispose();
    _model.dispose();
    _sharedKey.dispose();
    _localModel.dispose();
    super.dispose();
  }

  /// Ask the laptop what local models are installed (Ollama first,
  /// then LM Studio) and show them. Never throws: a failure is a
  /// plain status line.
  Future<void> _checkLocalModels() async {
    if (_localChecking) return;
    setState(() {
      _localChecking = true;
      _localStatus = 'Checking...';
    });
    final client = LocalModelClient();
    try {
      final choice = await client.detect();
      if (!mounted) return;
      if (choice == null) {
        setState(() {
          _localFound = [];
          _localStatus =
              'No local model is running. Start Ollama with `ollama serve`, or start the LM Studio server, then check again.';
        });
        return;
      }
      setState(() {
        _localFound = choice.models;
        _localKind = choice.kind;
        if (_localModel.text.trim().isEmpty) {
          _localModel.text = choice.model;
        }
        _localStatus =
            '${choice.kind == 'lmstudio' ? 'LM Studio' : 'Ollama'} is running: ${choice.models.join(', ')}';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _localFound = [];
        _localStatus = 'Could not check local models.';
      });
    } finally {
      client.close();
      if (mounted) setState(() => _localChecking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppConfig>(
      valueListenable: widget.app.config,
      builder: (context, config, _) {
        return ValueListenableBuilder<DjStatus?>(
          valueListenable: widget.app.status,
          builder: (context, status, _) {
            final cap = status?.capability;
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Settings',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 16),
                  _card(
                    title: 'Folders DJ searches',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final folder in config.folders)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text(
                              '${folder.enabled ? '' : '(disabled) '}${folder.path}',
                            ),
                          ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton(
                              onPressed: () => showFoldersDialog(
                                context,
                                app: widget.app,
                                firstRun: false,
                              ),
                              child: const Text('Folders'),
                            ),
                            OutlinedButton(
                              onPressed: () => widget.app.rebuildIndex(),
                              child: const Text('Rebuild index'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _card(
                    title: 'Capability',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${capabilityBadgeLabel(cap)}: ${cap?.message ?? 'Checking...'}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        if (cap != null && cap.local.available)
                          Text(
                            'Embedder: ${status?.embedderState ?? 'not started'} '
                            '(${status?.embedderSource ?? 'none'} model)',
                          )
                        else
                          Text(embedderLabel(status)),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: () =>
                              widget.app.refreshStatus(force: true),
                          child: const Text('Refresh status'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _card(
                    title: 'Shortcuts & Hotkeys',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Press your Hey DJ shortcut from any app (or click '
                          'the Dynamic Island at the top of your screen) to '
                          'ask about your screen or run a command.',
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Hey DJ Voice + Screen shortcut',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final preset in DjAppState.hotkeyPresets)
                              ChoiceChip(
                                label: Text(preset.label),
                                selected: (config.hotkeyPreset ?? 'ctrl_alt_d') ==
                                    preset.id,
                                onSelected: (_) async {
                                  final ok = await widget.app
                                      .applyHotkeyPreset(preset.id);
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        ok
                                            ? 'Shortcut set to ${preset.label}.'
                                            : '${preset.label} is already in use by another app.',
                                      ),
                                    ),
                                  );
                                },
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        const Text('• Finish speaking early: Ctrl + Shift + Space'),
                        const Text('• Command Palette: Ctrl + K'),
                        const Text('• Privacy Screen Pause / Resume: Ctrl + Alt + P'),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            ElevatedButton.icon(
                              onPressed: () =>
                                  runScreenQaFlow(context, widget.app),
                              icon: const Icon(Icons.auto_awesome, size: 18),
                              label: const Text('Test Hey DJ now'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _card(
                    title: 'Always running',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (Platform.isWindows) ...[
                          Row(
                            children: [
                              const Expanded(
                                child: Text('Start DJ when Windows starts'),
                              ),
                              Switch(
                                value: config.startAtLogin ?? false,
                                onChanged: (value) async {
                                  // setStartAtLogin throws when the native
                                  // side cannot change the registry key;
                                  // without this the switch silently stays
                                  // put and the error goes unhandled.
                                  try {
                                    final effective = await widget
                                        .app.systemOps
                                        .setStartAtLogin(value);
                                    await widget.app.saveConfig(
                                      config.copyWith(
                                          startAtLogin: effective),
                                    );
                                  } catch (_) {
                                    if (!context.mounted) return;
                                    ScaffoldMessenger.of(context)
                                        .showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          'Could not change start-at-login.',
                                        ),
                                      ),
                                    );
                                  }
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'DJ opens on its own when you sign in, and keeps '
                            'running in the tray when you close its window.',
                          ),
                        ] else
                          const Text('Not available on Android'),
                        if (status?.hasTray == true) ...[
                          const SizedBox(height: 8),
                          const Text(
                            'To fully quit DJ, right-click the tray icon '
                            'and choose Quit DJ.',
                          ),
                        ],
                        if (config.trayNoteSeen == true) ...[
                          const SizedBox(height: 8),
                          const Text(
                            'DJ keeps running in the tray. Right-click the '
                            'tray icon to open or quit.',
                          ),
                        ],
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            const Expanded(
                              child: Text('Speak screen answers aloud'),
                            ),
                            Switch(
                              value: config.speakScreenAnswers ?? false,
                              onChanged: (value) async {
                                await widget.app.saveConfig(
                                  config.copyWith(speakScreenAnswers: value),
                                );
                              },
                            ),
                          ],
                        ),
                        if (Platform.isAndroid) ...[
                          const SizedBox(height: 8),
                          ValueListenableBuilder<bool>(
                            valueListenable: widget.app.wakeWord.enabled,
                            builder: (context, wakeEnabled, _) => Row(
                              children: [
                                const Expanded(
                                  child: Text('Hands-free "Hey DJ" wake word'),
                                ),
                                Switch(
                                  value: wakeEnabled,
                                  onChanged: (value) =>
                                      widget.app.wakeWord.setEnabled(value),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _card(
                    title: 'Privacy Screen',
                    child: AnimatedBuilder(
                      animation: widget.app.privacyScreen,
                      builder: (context, _) {
                        final privacy = widget.app.privacyScreen;
                        if (!Platform.isWindows) {
                          return const Text(
                            'Privacy Screen is laptop-only. It needs a '
                            'Windows laptop with a webcam, so it does not '
                            'run on this phone.',
                          );
                        }
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              privacy.statusMessage,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                const Expanded(
                                  child: Text(
                                      'Start protection when DJ starts'),
                                ),
                                Switch(
                                  value: privacy.settings.startOnLaunch,
                                  onChanged: (value) => privacy
                                      .setStartOnLaunch(value),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Full controls — start/stop, sensitivity, '
                              'second-face warning and the Ctrl+Alt+P '
                              'override — are on the Privacy Screen page.',
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  _card(
                    title: 'About DJ',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'DJ v$kCurrentDjVersion — runs locally on your '
                          'device. Files never leave the laptop.',
                        ),
                        const SizedBox(height: 8),
                        const Text(windowsUpdateNote),
                        const SizedBox(height: 12),
                        ValueListenableBuilder<UpdateState>(
                          valueListenable: widget.app.updateState,
                          builder: (context, update, _) {
                            final checking = update.status == 'checking';
                            final downloading = update.status == 'downloading';
                            final ready = update.status == 'ready';
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (update.message.isNotEmpty) ...[
                                  Text(
                                    update.message,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: ready
                                          ? const Color(0xFF0071E3)
                                          : null,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                ],
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    OutlinedButton(
                                      onPressed: (checking || downloading)
                                          ? null
                                          : () => widget.app.checkForUpdates(
                                              userInitiated: true),
                                      child: Text(
                                        checking
                                            ? 'Checking...'
                                            : 'Check for updates',
                                      ),
                                    ),
                                    if (ready)
                                      ElevatedButton(
                                        onPressed: downloading
                                            ? null
                                            : () async {
                                                final messenger =
                                                    ScaffoldMessenger.of(
                                                        context);
                                                final res = await widget.app
                                                    .applyUpdateNow();
                                                if (res != null &&
                                                    context.mounted) {
                                                  if (!Platform.isWindows &&
                                                      res.startsWith('http')) {
                                                    await Clipboard.setData(
                                                        ClipboardData(
                                                            text: res));
                                                    messenger.showSnackBar(
                                                      const SnackBar(
                                                        content: Text(
                                                          'Copied APK link to clipboard.',
                                                        ),
                                                      ),
                                                    );
                                                  } else {
                                                    messenger.showSnackBar(
                                                      SnackBar(
                                                          content: Text(res)),
                                                    );
                                                  }
                                                }
                                              },
                                        child: Text(
                                          Platform.isWindows
                                              ? 'Update & Restart (v${update.version ?? ''})'
                                              : 'Copy APK Link (v${update.version ?? ''})',
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _card(
                    title: 'Account',
                    child: _accountCard(context),
                  ),
                  const SizedBox(height: 12),
                  _card(
                    title: 'Cloud (optional)',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Optional. DJ works fully without this. Keys live '
                          'in the Cloudflare Worker, never in the app. The '
                          'Worker URL is stored on this laptop only and '
                          'never logged. Gemini, Groq and NVIDIA NIM are '
                          'free — pick one, set its key as a Worker secret, '
                          'and type the model name.',
                        ),
                        const SizedBox(height: 12),
                        const Text('Worker URL'),
                        const SizedBox(height: 4),
                        TextField(
                          controller: _workerUrl,
                          decoration: const InputDecoration(
                            hintText: 'https://dj-worker.example.workers.dev',
                          ),
                          onChanged: (_) =>
                              setState(() => _cloudSaved = false),
                        ),
                        const SizedBox(height: 12),
                        const Text('Provider'),
                        const SizedBox(height: 4),
                        DropdownButton<String>(
                          value: _provider,
                          items: const [
                            DropdownMenuItem(
                                value: 'gemini',
                                child: Text('Gemini (free)')),
                            DropdownMenuItem(
                                value: 'groq', child: Text('Groq (free)')),
                            DropdownMenuItem(
                                value: 'nvidia',
                                child: Text('NVIDIA NIM (free)')),
                            DropdownMenuItem(
                                value: 'openai', child: Text('OpenAI')),
                            DropdownMenuItem(
                                value: 'openrouter',
                                child: Text('OpenRouter')),
                            DropdownMenuItem(
                                value: 'anthropic',
                                child: Text('Anthropic')),
                          ],
                          onChanged: (value) {
                            if (value == null) return;
                            setState(() {
                              _provider = value;
                              // Show the new provider's free default
                              // model; the user can type a newer one.
                              _model.text =
                                  DjAppState.defaultCloudModel(value);
                              _cloudSaved = false;
                            });
                          },
                        ),
                        const SizedBox(height: 12),
                        const Text('Model'),
                        const SizedBox(height: 4),
                        TextField(
                          controller: _model,
                          decoration: const InputDecoration(
                            hintText: 'gemini-3.8-flash',
                          ),
                          onChanged: (_) =>
                              setState(() => _cloudSaved = false),
                        ),
                        const SizedBox(height: 12),
                        const Text('Shared key'),
                        const SizedBox(height: 4),
                        TextField(
                          controller: _sharedKey,
                          obscureText: true,
                          decoration: const InputDecoration(
                            hintText:
                                'Optional — must match the Worker DJ_SHARED_KEY secret',
                          ),
                          onChanged: (_) =>
                              setState(() => _cloudSaved = false),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Leave blank when the Worker has no shared key '
                          'set — DJ then sends no key and keeps working.',
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            ElevatedButton(
                              onPressed: () {
                                widget.app.saveCloudSettings(
                                  CloudSettings(
                                    workerUrl: _workerUrl.text.trim(),
                                    provider: _provider,
                                    model: _model.text.trim(),
                                    sharedKey: _sharedKey.text.trim(),
                                  ),
                                );
                                setState(() => _cloudSaved = true);
                              },
                              child: const Text('Save cloud settings'),
                            ),
                            if (_cloudSaved) ...[
                              const SizedBox(width: 8),
                              const Text('Saved.'),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _card(
                    title: 'Local model (optional)',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Optional. DJ can answer with a model on this '
                          'laptop — no internet, no key. Start Ollama or '
                          'the LM Studio server first.',
                        ),
                        const SizedBox(height: 12),
                        const Text('Server'),
                        const SizedBox(height: 4),
                        DropdownButton<String>(
                          value: _localKind,
                          items: const [
                            DropdownMenuItem(
                                value: 'ollama', child: Text('Ollama')),
                            DropdownMenuItem(
                                value: 'lmstudio',
                                child: Text('LM Studio')),
                          ],
                          onChanged: (value) {
                            if (value == null) return;
                            setState(() {
                              _localKind = value;
                              _localSaved = false;
                            });
                          },
                        ),
                        const SizedBox(height: 12),
                        const Text('Model'),
                        const SizedBox(height: 4),
                        TextField(
                          controller: _localModel,
                          decoration: const InputDecoration(
                            hintText: 'qwen3.5:9b (blank = auto)',
                          ),
                          onChanged: (_) =>
                              setState(() => _localSaved = false),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            const Expanded(
                              child: Text('Answer with the local model first'),
                            ),
                            Switch(
                              value: _preferLocal,
                              onChanged: (value) {
                                setState(() {
                                  _preferLocal = value;
                                  _localSaved = false;
                                });
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'When off, DJ tries the cloud first and falls '
                          'back to the local model. When on, the local '
                          'model answers first.',
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton(
                              onPressed:
                                  _localChecking ? null : _checkLocalModels,
                              child: Text(_localChecking
                                  ? 'Checking...'
                                  : 'Check local models'),
                            ),
                            ElevatedButton(
                              onPressed: () async {
                                final model = _localModel.text.trim();
                                await widget.app.saveConfig(
                                  config.copyWith(
                                    localModel: LocalModelConfig(
                                      kind: _localKind,
                                      model:
                                          model.isEmpty ? null : model,
                                    ),
                                    preferLocal: _preferLocal,
                                  ),
                                );
                                setState(() => _localSaved = true);
                              },
                              child: const Text('Save local model'),
                            ),
                            if (_localSaved) ...[
                              const SizedBox(width: 8),
                              const Text('Saved.'),
                            ],
                          ],
                        ),
                        if (_localStatus.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(_localStatus),
                        ],
                        if (_localFound.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text('Models found: ${_localFound.join(', ')}'),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _accountCard(BuildContext context) {
    final account = widget.app.account;
    if (account == null) {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Set up Firebase first (see FIREBASE-SETUP.md)',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 4),
          Text(
            'DJ works fully without an account. The account only '
            'syncs routines, settings, summaries and memory between '
            'your laptop and phone.',
          ),
        ],
      );
    }
    return StreamBuilder(
      stream: account.signInStatus,
      initialData: account.auth.currentUserNow,
      builder: (context, snapshot) {
        final user = snapshot.data;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              user == null
                  ? 'Not signed in.'
                  : 'Signed in as ${user.email ?? 'your DJ account'}.',
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                if (user == null)
                  ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => SignInPage(
                            account: account,
                            onSignedIn: () =>
                                Navigator.of(context).pop(),
                            onContinueWithoutAccount: () =>
                                Navigator.of(context).pop(),
                          ),
                        ),
                      );
                    },
                    child: const Text('Sign in'),
                  )
                else
                  OutlinedButton(
                    onPressed: () async {
                      await account.signOut();
                    },
                    child: const Text('Sign out'),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _card({required String title, required Widget child}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}
