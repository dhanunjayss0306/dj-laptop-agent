// Home shell: top bar (DJ heading, capability badge + status dot,
// Search button opening the command palette), side navigation on wide
// screens with a Status section, bottom navigation on narrow screens,
// footer capability line, stale-index / update / tray-note banners.
// The shell also listens for the global hotkey / floating-button
// press and runs the ScreenQA flow on it.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models.dart';
import 'agent_page.dart';
import 'app_state.dart';
import 'command_page.dart';
import 'command_palette.dart';
import 'duplicates_page.dart';
import 'files_page.dart';
import 'folders_dialog.dart';
import 'memory_page.dart';
import 'organize_page.dart';
import 'privacy_screen_page.dart';
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
  ('Privacy Screen', Icons.visibility_off),
  ('Settings', Icons.settings),
];

// Narrow screens (<700px) show only these pages in the bottom bar:
// 5 items fit a phone width without truncating labels. The other
// pages live in the drawer (see _drawerIndices). _pages keeps its
// order: the wide side navigation still lists all 11 in order.
const List<int> _primaryIndices = [0, 1, 7, 8, 10];
const List<int> _drawerIndices = [2, 3, 4, 5, 6, 9];

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.app});

  final DjAppState app;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _current = 0;
  // Last primary tab shown in the bottom bar. When the current page
  // is a drawer-only page, the bottom bar keeps highlighting this
  // tab instead of pointing at the wrong page.
  int _lastPrimary = 0;
  StreamSubscription<void>? _hotkeySub;
  StreamSubscription<void>? _islandSub;
  StreamSubscription<void>? _cancelSub;
  bool _screenQaRunning = false;
  // Pages are built lazily: only the Command Center (index 0) exists
  // at startup. Every other page is built the first time it is opened
  // and then kept alive by the IndexedStack.
  //
  // This matters because IndexedStack builds ALL of its children on
  // the first frame, and several pages start heavy work in initState:
  // DuplicatesPage walks the whole home folder hashing files
  // (synchronous listSync/statSync + pure-Dart SHA-256, with no yield
  // to the event loop), SystemPage awaits a platform-channel call, and
  // MemoryPage reads files synchronously. Building all 11 pages before
  // the first frame meant the first frame could not be scheduled until
  // that work finished — a blank white window.
  final Set<int> _builtPages = {0};

  void _selectPage(int page) {
    setState(() {
      _builtPages.add(page);
      _current = page;
      final primary = _primaryIndices.indexOf(page);
      if (primary != -1) _lastPrimary = primary;
    });
    widget.app.privacyScreen.service.keepPreviewFrame = (page == 9);
  }

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
    _islandSub = widget.app.cursorChannel.onIslandClicked.listen((_) {
      if (_screenQaRunning || !mounted) return;
      _screenQaRunning = true;
      runScreenQaFlow(context, widget.app)
          .whenComplete(() => _screenQaRunning = false);
    });
    _cancelSub = widget.app.hotkeyChannel.onCancelPressed.listen((_) {
      widget.app.voiceChannel.stopSpeak();
      widget.app.cursorChannel.hideCursor();
      widget.app.updateCompanion('idle');
    });
    widget.app.pendingWakeCommand.addListener(_onWakeCommand);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!widget.app.indexer.hasIndex()) {
        showFoldersDialog(context, app: widget.app, firstRun: true);
      }
    });
  }

  void _onWakeCommand() {
    final cmd = widget.app.pendingWakeCommand.value;
    if (cmd == null || _screenQaRunning || !mounted) return;
    widget.app.pendingWakeCommand.value = null;
    _screenQaRunning = true;
    runScreenQaFlow(context, widget.app, initialCommand: cmd)
        .whenComplete(() => _screenQaRunning = false);
  }

  @override
  void dispose() {
    widget.app.pendingWakeCommand.removeListener(_onWakeCommand);
    _hotkeySub?.cancel();
    _islandSub?.cancel();
    _cancelSub?.cancel();
    super.dispose();
  }

  void _openPalette() {
    showCommandPalette(
      context,
      widget.app,
      PaletteActions(
        goToPage: _selectPage,
        rebuildIndex: () => widget.app.rebuildIndex(),
        openFolders: () => showFoldersDialog(
          context,
          app: widget.app,
          firstRun: false,
        ),
        refreshStatus: () => widget.app.refreshStatus(force: true),
        askScreen: () {
          if (_screenQaRunning || !mounted) return;
          _screenQaRunning = true;
          runScreenQaFlow(context, widget.app)
              .whenComplete(() => _screenQaRunning = false);
        },
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
            // Bottom-bar position of the current page; drawer-only
            // pages leave the last primary tab highlighted.
            final primaryIndex = _primaryIndices.indexOf(_current);
            final bottomIndex =
                primaryIndex == -1 ? _lastPrimary : primaryIndex;
            return Scaffold(
              appBar: AppBar(
                title: wide
                    ? Row(
                        children: [
                          const Text('DJ'),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: _HeaderDynamicIsland(
                                app: app,
                                onTapIsland: () {
                                  if (_screenQaRunning) return;
                                  _screenQaRunning = true;
                                  runScreenQaFlow(context, app).whenComplete(
                                      () => _screenQaRunning = false);
                                },
                                onTapPalette: _openPalette,
                              ),
                            ),
                          ),
                        ],
                      )
                    : const Text('DJ'),
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
                          label: Text(capabilityBadgeChipLabel(cap)),
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
                  if (wide && Platform.isWindows)
                    ValueListenableBuilder<bool>(
                      valueListenable: app.companionFollow,
                      builder: (context, following, _) {
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: OutlinedButton.icon(
                            onPressed: () =>
                                app.setCompanionFollow(!following),
                            icon: Icon(
                              following
                                  ? Icons.near_me
                                  : Icons.near_me_outlined,
                              size: 18,
                              color:
                                  following ? const Color(0xFF0071E3) : null,
                            ),
                            label: Text(
                              following ? 'Floating DJ' : 'Float DJ',
                            ),
                          ),
                        );
                      },
                    ),
                  // Narrow screens: the provider chip ('Cloud (gemini)')
                  // plus the hamburger plus a labelled Search button
                  // overflow a 390px AppBar by ~23px, so the Search
                  // button is icon-only there; wide keeps the label.
                  wide
                      ? Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: OutlinedButton.icon(
                            onPressed: _openPalette,
                            icon: const Icon(Icons.search, size: 18),
                            label: const Text('Search'),
                          ),
                        )
                      : IconButton(
                          tooltip: 'Search',
                          onPressed: _openPalette,
                          icon: const Icon(Icons.search),
                        ),
                ],
              ),
              body: Column(
                children: [
                  _DynamicIslandPill(app: app),
                  _Banners(app: app),
                  Expanded(
                    child: wide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _SideNav(
                                app: app,
                                current: _current,
                                onSelect: _selectPage,
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
              // Narrow screens get a drawer for the pages that do
              // not fit in the bottom bar; its hamburger icon
              // appears in the AppBar automatically.
              drawer: wide
                  ? null
                  : Drawer(
                      backgroundColor: const Color(0xFFFFFFFF),
                      child: _NarrowDrawer(
                        current: _current,
                        onSelect: _selectPage,
                      ),
                    ),
              bottomNavigationBar: wide
                  ? null
                  : BottomNavigationBar(
                      currentIndex: bottomIndex,
                      onTap: (i) => _selectPage(_primaryIndices[i]),
                      // Material 3 defaults (14/12) truncate the
                      // "Command Center" label in a fifth of a phone
                      // width; 11 keeps all five labels readable.
                      selectedFontSize: 11,
                      unselectedFontSize: 11,
                      items: [
                        for (final i in _primaryIndices)
                          BottomNavigationBarItem(
                            icon: Icon(_pages[i].$2, size: 22),
                            label: _pages[i].$1,
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
    // Unvisited pages are placeholders until first opened (see
    // _builtPages): their initState work must not run at startup.
    Widget page(int i) {
      if (!_builtPages.contains(i)) return const SizedBox.shrink();
      return switch (i) {
        0 => CommandPage(app: app),
        1 => FilesPage(app: app),
        2 => DuplicatesPage(app: app),
        3 => OrganizePage(app: app),
        4 => SystemPage(app: app),
        5 => MemoryPage(app: app),
        6 => RoutinesPage(app: app),
        7 => AgentPage(app: app),
        8 => ToolsPage(app: app),
        9 => PrivacyScreenPage(app: app),
        _ => SettingsPage(app: app),
      };
    }

    return IndexedStack(
      index: _current,
      children: [for (var i = 0; i < _pages.length; i++) page(i)],
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

// Drawer content on narrow screens: the pages that do not fit in
// the 5-item bottom bar. Same titles, icons and order as _pages.
class _NarrowDrawer extends StatelessWidget {
  const _NarrowDrawer({
    required this.current,
    required this.onSelect,
  });

  final int current;
  final void Function(int index) onSelect;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
          decoration: const BoxDecoration(
            border: Border(
                bottom: BorderSide(color: Color(0xFFE5E5E5))),
          ),
          child: const Text(
            'More',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        for (final i in _drawerIndices)
          ListTile(
            leading: Icon(_pages[i].$2, size: 20),
            title: Text(_pages[i].$1),
            selected: current == i,
            selectedTileColor: const Color(0xFFF5F5F7),
            onTap: () {
              Navigator.of(context).pop();
              onSelect(i);
            },
          ),
      ],
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
        // Privacy Screen override: always visible while protection is
        // paused, on every page, so he always knows protection is off.
        // The tray tooltip cannot change from Dart, so this banner is
        // the app-wide status for the override.
        AnimatedBuilder(
          animation: app.privacyScreen,
          builder: (context, _) {
            if (!app.privacyScreen.isOverrideOn) {
              return const SizedBox.shrink();
            }
            return Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: const BoxDecoration(
                color: Color(0xFFFFF8E1),
                border:
                    Border(bottom: BorderSide(color: Color(0xFF9A6A00))),
              ),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Privacy paused — press Ctrl+Alt+P to resume',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  TextButton(
                    onPressed: () => app.privacyScreen.setOverride(false),
                    child: const Text('Resume protection'),
                  ),
                ],
              ),
            );
          },
        ),
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
            if (update.status == 'downloading') {
              return _banner(context, text: update.message);
            }
            if (update.status != 'ready') return const SizedBox.shrink();
            return _banner(
              context,
              text: update.message,
              actionLabel:
                  Platform.isWindows ? 'Update & Restart' : 'Copy APK link',
              onAction: () async {
                final messenger = ScaffoldMessenger.of(context);
                final res = await app.applyUpdateNow();
                if (res != null && context.mounted) {
                  if (!Platform.isWindows && res.startsWith('http')) {
                    await Clipboard.setData(ClipboardData(text: res));
                    messenger.showSnackBar(
                      const SnackBar(
                        content: Text('Copied Android APK download link.'),
                      ),
                    );
                  } else {
                    messenger.showSnackBar(SnackBar(content: Text(res)));
                  }
                }
              },
            );
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

/// iOS-style Dynamic Island pill inside the app header. Shows "Ask DJ" when
/// idle and expands with live streaming captions ("fake lyrics") while
/// listening, thinking, or speaking.
class _DynamicIslandPill extends StatelessWidget {
  const _DynamicIslandPill({required this.app});

  final DjAppState app;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<({String state, String text})>(
      valueListenable: app.companionState,
      builder: (context, companion, _) {
        if (companion.state == 'idle') return const SizedBox.shrink();
        final dotColor = switch (companion.state) {
          'listening' => const Color(0xFF22C55E),
          'thinking' => const Color(0xFFA78BFA),
          'responding' => const Color(0xFF0071E3),
          _ => const Color(0xFF0071E3),
        };
        final label = companion.text.isNotEmpty
            ? companion.text
            : switch (companion.state) {
                'listening' => 'Listening...',
                'thinking' => 'Thinking...',
                _ => 'DJ',
              };
        return Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 6),
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              constraints: const BoxConstraints(
                maxWidth: 460,
                minWidth: 240,
              ),
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF111114),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: dotColor),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: dotColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () {
                      app.voiceChannel.stopSpeak();
                      app.cursorChannel.hideCursor();
                      app.updateCompanion('idle');
                    },
                    child: const Icon(
                      Icons.close,
                      size: 16,
                      color: Color(0xFFB0B0B8),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Persistent compact Dynamic Island capsule centered in the wide AppBar so the
/// user always sees where to click for Hey DJ voice/screen help & shortcuts.
class _HeaderDynamicIsland extends StatelessWidget {
  const _HeaderDynamicIsland({
    required this.app,
    required this.onTapIsland,
    required this.onTapPalette,
  });

  final DjAppState app;
  final VoidCallback onTapIsland;
  final VoidCallback onTapPalette;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppConfig>(
      valueListenable: app.config,
      builder: (context, config, _) {
        return ValueListenableBuilder<({String state, String text})>(
          valueListenable: app.companionState,
          builder: (context, companion, _) {
            final active = companion.state != 'idle';
            final dotColor = switch (companion.state) {
              'listening' => const Color(0xFF22C55E),
              'thinking' => const Color(0xFFA78BFA),
              _ => const Color(0xFF0071E3),
            };
            final label = active && companion.text.isNotEmpty
                ? companion.text
                : 'Hey DJ  •  ${app.currentHotkeyLabel}';
            return Material(
              color: const Color(0xFF111116),
              borderRadius: BorderRadius.circular(20),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 360),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: active ? dotColor : const Color(0xFF2C2C34),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: InkWell(
                        borderRadius: const BorderRadius.horizontal(
                          left: Radius.circular(20),
                        ),
                        onTap: onTapIsland,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: dotColor,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Container(
                      width: 1,
                      height: 16,
                      color: const Color(0xFF2C2C34),
                    ),
                    InkWell(
                      borderRadius: const BorderRadius.horizontal(
                        right: Radius.circular(20),
                      ),
                      onTap: onTapPalette,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        child: Text(
                          'Ctrl+K',
                          style: TextStyle(
                            color: Color(0xFFA1A1AA),
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
