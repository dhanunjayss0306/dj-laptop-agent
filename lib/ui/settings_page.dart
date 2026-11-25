// Settings page: 4 cards (Folders, Capability, Always running, About DJ)
// plus a small optional Cloud section. The Cloud section is new UI:
// keys live in the Cloudflare Worker, never in the app.
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../platform/update_note.dart';
import 'app_state.dart';
import 'folders_dialog.dart';
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
  bool _cloudSaved = false;

  @override
  void initState() {
    super.initState();
    final cloud = widget.app.loadCloudSettings();
    _workerUrl = TextEditingController(text: cloud.workerUrl);
    _provider = cloud.provider;
  }

  @override
  void dispose() {
    _workerUrl.dispose();
    super.dispose();
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
                        Row(
                          children: [
                            OutlinedButton(
                              onPressed: () => showFoldersDialog(
                                context,
                                app: widget.app,
                                firstRun: false,
                              ),
                              child: const Text('Folders'),
                            ),
                            const SizedBox(width: 8),
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
                                  final effective = await widget
                                      .app.systemOps
                                      .setStartAtLogin(value);
                                  await widget.app.saveConfig(
                                    config.copyWith(
                                        startAtLogin: effective),
                                  );
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
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _card(
                    title: 'About DJ',
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'DJ runs on this laptop only. Files never leave '
                          'the laptop, and DJ works with no model and no '
                          'API key.',
                        ),
                        SizedBox(height: 8),
                        Text(windowsUpdateNote),
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
                          'never logged.',
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
                                value: 'openai', child: Text('openai')),
                            DropdownMenuItem(
                                value: 'openrouter',
                                child: Text('openrouter')),
                            DropdownMenuItem(
                                value: 'anthropic',
                                child: Text('anthropic')),
                          ],
                          onChanged: (value) {
                            if (value == null) return;
                            setState(() {
                              _provider = value;
                              _cloudSaved = false;
                            });
                          },
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
