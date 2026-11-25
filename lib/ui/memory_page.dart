// Memory page: read-only. Tabs for Long-term (MEMORY.md) and Daily
// notes (last 14, newest first). Search filters lines
// case-insensitively. Empty file shows an empty state, never
// placeholder text.
import 'package:flutter/material.dart';

import 'app_state.dart';

class MemoryPage extends StatefulWidget {
  const MemoryPage({super.key, required this.app});

  final DjAppState app;

  @override
  State<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends State<MemoryPage> {
  final TextEditingController _search = TextEditingController();
  late final String _memoryMd;
  late final List<({String date, String text})> _daily;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    final content = widget.app.memory.readContent();
    _memoryMd = content.memoryMd;
    _daily = content.daily;
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<String> _filteredLines(String text) {
    final q = _search.text.trim().toLowerCase();
    final lines = text.split('\n');
    if (q.isEmpty) return lines;
    return lines.where((l) => l.toLowerCase().contains(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Memory',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              ChoiceChip(
                label: const Text('Long-term'),
                selected: _tab == 0,
                onSelected: (_) => setState(() => _tab = 0),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('Daily notes'),
                selected: _tab == 1,
                onSelected: (_) => setState(() => _tab = 1),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _search,
            decoration: const InputDecoration(
              hintText: 'Search memory...',
              prefixIcon: Icon(Icons.search),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _tab == 0 ? _longTermTab() : _dailyTab(),
          ),
        ],
      ),
    );
  }

  Widget _longTermTab() {
    if (_memoryMd.trim().isEmpty) {
      return const Center(child: Text('No long-term memory yet.'));
    }
    final lines = _filteredLines(_memoryMd);
    if (lines.isEmpty) {
      return const Center(child: Text('Nothing matches that search.'));
    }
    return SingleChildScrollView(
      child: Text(lines.join('\n')),
    );
  }

  Widget _dailyTab() {
    if (_daily.isEmpty) {
      return const Center(child: Text('No daily notes yet.'));
    }
    final query = _search.text.trim().toLowerCase();
    final shown = _daily.where((day) {
      if (query.isEmpty) return true;
      return day.text.toLowerCase().contains(query);
    }).toList();
    if (shown.isEmpty) {
      return const Center(child: Text('Nothing matches that search.'));
    }
    return ListView.separated(
      itemCount: shown.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, i) {
        final day = shown[i];
        final lines = _filteredLines(day.text);
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  day.date,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(lines.join('\n')),
              ],
            ),
          ),
        );
      },
    );
  }
}
