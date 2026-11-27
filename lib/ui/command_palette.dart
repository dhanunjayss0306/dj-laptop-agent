// Command palette (Ctrl+K / Cmd+K anywhere): 16 commands, 11 pages +
// 5 actions. Filters as you type; empty result shows
// "No matching page or action".
import 'package:flutter/material.dart';

import 'app_state.dart';

class PaletteActions {
  const PaletteActions({
    required this.goToPage,
    required this.rebuildIndex,
    required this.openFolders,
    required this.refreshStatus,
    this.askScreen,
  });

  /// Page index 0-10: Command Center, Files, Duplicates, Organize,
  /// System, Memory, Routines, Agent, Tools, Privacy Screen, Settings.
  final void Function(int page) goToPage;
  final VoidCallback rebuildIndex;
  final VoidCallback openFolders;
  final VoidCallback refreshStatus;
  final VoidCallback? askScreen;
}

class _PaletteCommand {
  const _PaletteCommand({
    required this.title,
    required this.group,
    required this.keywords,
    required this.icon,
    required this.run,
  });

  final String title;
  final String group;
  final String keywords;
  final IconData icon;
  final VoidCallback run;
}

Future<void> showCommandPalette(
  BuildContext context,
  DjAppState app,
  PaletteActions actions,
) async {
  await showDialog<void>(
    context: context,
    builder: (context) =>
        _CommandPaletteDialog(app: app, actions: actions),
  );
}

class _CommandPaletteDialog extends StatefulWidget {
  const _CommandPaletteDialog({required this.app, required this.actions});

  final DjAppState app;
  final PaletteActions actions;

  @override
  State<_CommandPaletteDialog> createState() => _CommandPaletteDialogState();
}

class _CommandPaletteDialogState extends State<_CommandPaletteDialog> {
  final TextEditingController _query = TextEditingController();

  late final List<_PaletteCommand> _all = [
    _PaletteCommand(
      title: 'Go to Command Center',
      group: 'Pages',
      keywords: 'command center chat home',
      icon: Icons.chat,
      run: () => widget.actions.goToPage(0),
    ),
    _PaletteCommand(
      title: 'Go to Files',
      group: 'Pages',
      keywords: 'files find search open',
      icon: Icons.folder,
      run: () => widget.actions.goToPage(1),
    ),
    _PaletteCommand(
      title: 'Go to Duplicates',
      group: 'Pages',
      keywords: 'duplicates copies extra',
      icon: Icons.copy,
      run: () => widget.actions.goToPage(2),
    ),
    _PaletteCommand(
      title: 'Go to Organize',
      group: 'Pages',
      keywords: 'organize downloads move tidy',
      icon: Icons.cleaning_services,
      run: () => widget.actions.goToPage(3),
    ),
    _PaletteCommand(
      title: 'Go to System',
      group: 'Pages',
      keywords: 'system cpu ram stats',
      icon: Icons.monitor,
      run: () => widget.actions.goToPage(4),
    ),
    _PaletteCommand(
      title: 'Go to Memory',
      group: 'Pages',
      keywords: 'memory notes daily',
      icon: Icons.note,
      run: () => widget.actions.goToPage(5),
    ),
    _PaletteCommand(
      title: 'Go to Routines',
      group: 'Pages',
      keywords: 'routines morning wind down run',
      icon: Icons.list,
      run: () => widget.actions.goToPage(6),
    ),
    _PaletteCommand(
      title: 'Go to Agent',
      group: 'Pages',
      keywords: 'agent task do run',
      icon: Icons.smart_toy,
      run: () => widget.actions.goToPage(7),
    ),
    _PaletteCommand(
      title: 'Go to Tools',
      group: 'Pages',
      keywords: 'tools tutor integrations walkthrough',
      icon: Icons.build,
      run: () => widget.actions.goToPage(8),
    ),
    _PaletteCommand(
      title: 'Go to Privacy Screen',
      group: 'Pages',
      keywords: 'privacy screen webcam blackout shoulder',
      icon: Icons.visibility_off,
      run: () => widget.actions.goToPage(9),
    ),
    _PaletteCommand(
      title: 'Go to Settings',
      group: 'Pages',
      keywords: 'settings folders config',
      icon: Icons.settings,
      run: () => widget.actions.goToPage(10),
    ),
    _PaletteCommand(
      title: 'Rebuild index',
      group: 'Actions',
      keywords: 'index rebuild scan',
      icon: Icons.refresh,
      run: widget.actions.rebuildIndex,
    ),
    _PaletteCommand(
      title: 'Open folders settings',
      group: 'Actions',
      keywords: 'folders settings add folder',
      icon: Icons.create_new_folder,
      run: widget.actions.openFolders,
    ),
    _PaletteCommand(
      title: 'Find duplicates',
      group: 'Actions',
      keywords: 'duplicates copies extra',
      icon: Icons.copy,
      run: () => widget.actions.goToPage(2),
    ),
    _PaletteCommand(
      title: 'Organize Downloads',
      group: 'Actions',
      keywords: 'organize downloads move',
      icon: Icons.cleaning_services,
      run: () => widget.actions.goToPage(3),
    ),
    _PaletteCommand(
      title: 'Refresh status',
      group: 'Actions',
      keywords: 'refresh status reload',
      icon: Icons.refresh,
      run: widget.actions.refreshStatus,
    ),
    if (widget.actions.askScreen != null)
      _PaletteCommand(
        title: 'Ask DJ (Voice + Screen)',
        group: 'Actions',
        keywords: 'hey dj voice screen hotkey ask dynamic island',
        icon: Icons.auto_awesome,
        run: widget.actions.askScreen!,
      ),
    _PaletteCommand(
      title: 'Shortcuts & Hotkeys',
      group: 'Actions',
      keywords: 'shortcut hotkey keybinding settings customize',
      icon: Icons.keyboard,
      run: () => widget.actions.goToPage(10),
    ),
  ];

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<_PaletteCommand> get _filtered {
    final q = _query.text.trim().toLowerCase();
    if (q.isEmpty) return _all;
    return _all
        .where((c) =>
            c.title.toLowerCase().contains(q) ||
            c.keywords.toLowerCase().contains(q))
        .toList();
  }

  void _run(_PaletteCommand command) {
    Navigator.of(context).pop();
    // Run after the palette closes, so dialogs opened by an action
    // (for example Folders) use a live context.
    Future<void>.delayed(Duration.zero, command.run);
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return AlertDialog(
      contentPadding: const EdgeInsets.all(8),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _query,
              autofocus: true,
              onSubmitted: (_) {
                if (filtered.isNotEmpty) _run(filtered.first);
              },
              decoration: const InputDecoration(
                hintText: 'Type to search pages and actions',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: filtered.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('No matching page or action'),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: filtered.length,
                      itemBuilder: (context, i) {
                        final command = filtered[i];
                        final showGroup = i == 0 ||
                            filtered[i - 1].group != command.group;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (showGroup)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                    12, 12, 12, 4),
                                child: Text(
                                  command.group,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ListTile(
                              leading: Icon(command.icon, size: 20),
                              title: Text(command.title),
                              onTap: () => _run(command),
                            ),
                          ],
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
