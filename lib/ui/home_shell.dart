// Home shell: top bar (DJ heading, capability badge + status dot,
// Search button opening the command palette), side navigation on wide
// screens with a Status section, bottom navigation on narrow screens,
// footer capability line, stale-index / update / tray-note banners.
// The shell also listens for the global hotkey / floating-button
// press and runs the ScreenQA flow on it.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'agent_page.dart';
import 'app_state.dart';
import 'command_page.dart';
import 'command_palette.dart';
import 'duplicates_page.dart';
import 'files_page.dart';
import 'folders_dialog.dart';
import 'memory_page.dart';
import 'organize_page.dart';
import 'routines_page.dart';
import 'screen_qa_flow.dart';
import 'settings_page.dart';
import 'system_page.dart';
import 'tools_page.dart';

const List<(String title, IconData icon)> _pages = [
  ('Command Center', Icons.chat),
  ('Files', Icons.folder),
  ('Duplicates', Icons.copy),
  ('Organize', Icons.cleaning_services),
  ('System', Icons.monitor),
  ('Memory', Icons.note),
  ('Routines', Icons.list),
  ('Agent', Icons.smart_toy),
  ('Tools', Icons.build),
  ('Settings', Icons.settings),
];

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.app});

  final DjAppState app;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _current = 0;
  StreamSubscription<void>? _hotkeySub;
  bool _screenQaRunning = false;

  @override
  void initState() {
    super.initState();
    // Hotkey press / floating-button tap: capture the screen once
    // and ask what the user wants to know. One flow at a time.
    _hotkeySub = widget.app.hotkeyChannel.onHotkeyPressed.listen((_) {
      if (_screenQaRunning || !mounted) return;
      _screenQaRunning = true;
      runScreenQaFlow(context, widget.app)
          .whenComplete(() => _screenQaRunning = false);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!widget.app.indexer.hasIndex()) {
        showFoldersDialog(context, app: widget.app, firstRun: true);
      }
    });
  }

  @override
  void dispose() {
    _hotkeySub?.cancel();
    super.dispose();
  }

  void _openPalette() {
    showCommandPalette(
      context,
      widget.app,
      PaletteActions(
        goToPage: (page) => setState(() => _current = page),
        rebuildIndex: () => widget.app.rebuildIndex(),
        openFolders: () => showFoldersDialog(
          context,
          app: widget.app,
          firstRun: false,
        ),
        refreshStatus: () => widget.app.refreshStatus(force: true),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            _openPalette,
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
            _openPalette,
      },
      child: Focus(
        autofocus: true,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 700;
            return Scaffold(
              appBar: AppBar(
                title: const Text('DJ'),
                actions: [
                  ValueListenableBuilder(
                    valueListenable: app.status,
                    builder: (context, status, _) {
                      final cap = status?.capability;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Chip(
                          avatar: Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: capabilityBadgeColor(cap),
                              shape: BoxShape.circle,
                            ),
                          ),
                          label: Text(capabilityBadgeLabel(cap)),
                          backgroundColor: const Color(0xFFFFFFFF),
                          side: const BorderSide(
                              color: Color(0xFFE5E5E5)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      );
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: OutlinedButton.icon(
                      onPressed: _openPalette,
                      icon: const Icon(Icons.search, size: 18),
                      label: const Text('Search'),
                    ),
                  ),
                ],
              ),
              body: Column(
                children: [
                  _Banners(app: app),
                  Expanded(
                    child: wide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _SideNav(
                                app: app,
                                current: _current,
                                onSelect: (i) =>
                                    setState(() => _current = i),
                              ),
                              const VerticalDivider(width: 1),
                              Expanded(child: _body()),
                            ],
                          )
                        : _body(),
                  ),
                  _Footer(app: app),
                ],
              ),
              bottomNavigationBar: wide
                  ? null
                  : BottomNavigationBar(
                      currentIndex: _current,
                      onTap: (i) => setState(() => _current = i),
                      items: [
                        for (final (title, icon) in _pages)
                          BottomNavigationBarItem(
                            icon: Icon(icon, size: 22),
                            label: title,
                          ),
                      ],
                    ),
            );
          },
        ),
      ),
    );
  }

  Widget _body() {
    final app = widget.app;
    return IndexedStack(
      index: _current,
      children: [
        CommandPage(app: app),
        FilesPage(app: app),
        DuplicatesPage(app: app),
        OrganizePage(app: app),
        SystemPage(app: app),
        MemoryPage(app: app),
        RoutinesPage(app: app),
        AgentPage(app: app),
        ToolsPage(app: app),
        SettingsPage(app: app),
      ],
    );
  }
}

class _SideNav extends StatelessWidget {
  const _SideNav({
    required this.app,
    required this.current,
    required this.onSelect,
  });

  final DjAppState app;
  final int current;
  final void Function(int index) onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 232,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                for (var i = 0; i < _pages.length; i++)
                  ListTile(
                    leading: Icon(_pages[i].$2, size: 20),
                    title: Text(_pages[i].$1),
                    selected: current == i,
                    selectedTileColor: const Color(0xFFF5F5F7),
                    onTap: () => onSelect(i),
                  ),
                const Divider(),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    'Status',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                ValueListenableBuilder(
                  valueListenable: app.status,
                  builder: (context, status, _) {
                    return Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            status == null
                                ? 'Loading status...'
                                : '${status.filesIndexed} files indexed',
                          ),
                          const SizedBox(height: 4),
                          Text(searchModeLabel(status)),
                          const SizedBox(height: 4),
                          Text(embedderLabel(status)),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Banners extends StatelessWidget {
  const _Banners({required this.app});

  final DjAppState app;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ValueListenableBuilder(
          valueListenable: app.status,
          builder: (context, status, _) {
            if (status == null || !status.indexStale) {
              return const SizedBox.shrink();
            }
            return _banner(
              context,
              text:
                  'The search index was built with an older format — Rebuild index to use meaning search.',
              actionLabel: 'Rebuild index',
              onAction: () => app.rebuildIndex(),
            );
          },
        ),
        ValueListenableBuilder(
          valueListenable: app.updateState,
          builder: (context, update, _) {
            if (update.status != 'ready') return const SizedBox.shrink();
            return _banner(context, text: update.message);
          },
        ),
        ValueListenableBuilder(
          valueListenable: app.trayNoteVisible,
          builder: (context, visible, _) {
            if (!visible) return const SizedBox.shrink();
            return _banner(
              context,
              text:
                  'DJ keeps running in the tray. Right-click the tray icon to open or quit.',
              onDismiss: () => app.dismissTrayNote(),
            );
          },
        ),
      ],
    );
  }

  Widget _banner(
    BuildContext context, {
    required String text,
    String? actionLabel,
    VoidCallback? onAction,
    VoidCallback? onDismiss,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0xFFF5F5F7),
        border: Border(bottom: BorderSide(color: Color(0xFFE5E5E5))),
      ),
      child: Row(
        children: [
          Expanded(child: Text(text)),
          if (actionLabel != null)
            TextButton(
              onPressed: onAction,
              child: Text(actionLabel),
            ),
          if (onDismiss != null)
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: onDismiss,
            ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.app});

  final DjAppState app;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: app.status,
      builder: (context, status, _) {
        final message = status?.capability.message ?? 'Checking...';
        return Container(
          width: double.infinity,
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: Color(0xFFE5E5E5))),
          ),
          child: Text(message, style: const TextStyle(fontSize: 12)),
        );
      },
    );
  }
}
