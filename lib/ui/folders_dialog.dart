// Folders dialog: first-run ("Set up DJ", required, "Save and build
// index") and settings ("Folders", "Save"). Rows have an enable
// checkbox (full path) + Remove. Add folder uses the native picker.
// Duplicates are ignored. Save is disabled with 0 enabled folders.
// Saving stores the config and starts a full index rebuild.
import 'package:flutter/material.dart';

import '../core/models.dart';
import 'app_state.dart';

class _FolderRowState {
  _FolderRowState({required this.path, required this.enabled});

  String path;
  bool enabled;
}

Future<void> showFoldersDialog(
  BuildContext context, {
  required DjAppState app,
  required bool firstRun,
}) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: !firstRun,
    builder: (context) => _FoldersDialog(app: app, firstRun: firstRun),
  );
}

class _FoldersDialog extends StatefulWidget {
  const _FoldersDialog({required this.app, required this.firstRun});

  final DjAppState app;
  final bool firstRun;

  @override
  State<_FoldersDialog> createState() => _FoldersDialogState();
}

class _FoldersDialogState extends State<_FoldersDialog> {
  late final List<_FolderRowState> _rows;

  @override
  void initState() {
    super.initState();
    _rows = widget.app.config.value.folders
        .map((f) => _FolderRowState(path: f.path, enabled: f.enabled))
        .toList();
  }

  bool get _canSave => _rows.any((r) => r.enabled);

  Future<void> _addFolder() async {
    final picked = await widget.app.systemOps.pickFolder();
    if (picked == null || picked.isEmpty) return;
    if (_rows.any((r) => r.path == picked)) return;
    setState(() => _rows.add(_FolderRowState(path: picked, enabled: true)));
  }

  Future<void> _save() async {
    if (!_canSave) return;
    final config = widget.app.config.value.copyWith(
      folders: _rows
          .map((r) => FolderEntry(path: r.path, enabled: r.enabled))
          .toList(),
    );
    await widget.app.saveConfig(config);
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Folders saved. Rebuilding index.')),
    );
    // Start the rebuild in the background; the progress bar shows it.
    // ignore: unawaited_futures
    widget.app.rebuildIndex();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.firstRun ? 'Set up DJ' : 'Folders'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.firstRun)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  'Choose the folders DJ searches. DJ never indexes '
                  'the whole drive.',
                ),
              ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (var i = 0; i < _rows.length; i++)
                    Row(
                      children: [
                        Checkbox(
                          value: _rows[i].enabled,
                          onChanged: (v) => setState(
                              () => _rows[i].enabled = v ?? false),
                        ),
                        Expanded(
                          child: Text(
                            _rows[i].path,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton(
                          onPressed: () =>
                              setState(() => _rows.removeAt(i)),
                          child: const Text('Remove'),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _addFolder,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add folder'),
            ),
          ],
        ),
      ),
      actions: [
        if (!widget.firstRun)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ElevatedButton(
          onPressed: _canSave ? _save : null,
          child: Text(widget.firstRun ? 'Save and build index' : 'Save'),
        ),
      ],
    );
  }
}
