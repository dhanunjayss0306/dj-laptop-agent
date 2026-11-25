// Files page: search box, Search + Rebuild index buttons, Explorer-style
// result rows, empty state with a Rebuild-index action, progress bar
// during index builds.
import 'package:flutter/material.dart';

import '../core/models.dart';
import 'app_state.dart';
import 'file_row.dart';

class FilesPage extends StatefulWidget {
  const FilesPage({super.key, required this.app});

  final DjAppState app;

  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  final TextEditingController _query = TextEditingController();
  List<SearchResult>? _results;
  bool _searching = false;
  String? _meaningNote;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    setState(() => _searching = true);
    final results = await widget.app.indexer.search(q, 8);
    if (!mounted) return;
    setState(() {
      _results = results;
      _searching = false;
      _meaningNote = results.isNotEmpty ? results.first.note : null;
    });
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
    final results = _results;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Files',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _query,
                  onSubmitted: (_) => _search(),
                  decoration: const InputDecoration(
                    hintText: 'Find a file by name or by what is inside it...',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _searching ? null : _search,
                child: const Text('Search'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => widget.app.rebuildIndex(),
                child: const Text('Rebuild index'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ValueListenableBuilder<IndexProgress?>(
            valueListenable: widget.app.indexProgress,
            builder: (context, progress, _) {
              if (progress == null) return const SizedBox.shrink();
              final percent = progress.total > 0
                  ? progress.done / progress.total
                  : null;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(progress.message),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(
                    value: percent,
                    backgroundColor: const Color(0xFFE5E5E5),
                    color: const Color(0xFF0071E3),
                  ),
                  const SizedBox(height: 12),
                ],
              );
            },
          ),
          if (_searching)
            const Expanded(
              child: Center(child: CircularProgressIndicator()),
            )
          else if (results == null)
            const Expanded(
              child: Center(
                child: Text(
                  'Search your indexed files by name or by what is inside them.',
                ),
              ),
            )
          else if (results.isEmpty)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('No files found.'),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: () => widget.app.rebuildIndex(),
                      child: const Text('Rebuild index'),
                    ),
                  ],
                ),
              ),
            )
          else
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_meaningNote != null && _meaningNote!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(_meaningNote!),
                    ),
                  Expanded(
                    child: ListView.separated(
                      itemCount: results.length,
                      separatorBuilder: (_, __) => const Divider(),
                      itemBuilder: (context, i) => FileRow(
                        result: results[i],
                        onOpen: () => _openFile(results[i].path),
                      ),
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
