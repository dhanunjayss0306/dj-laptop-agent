// Routines page: built-in + saved routines, run one, delete one,
// save a simple one-step routine. All storage and running lives in
// RoutineStore; this page only shows it.
import 'package:flutter/material.dart';

import '../features/routines.dart';
import 'app_state.dart';

class RoutinesPage extends StatefulWidget {
  const RoutinesPage({super.key, required this.app});

  final DjAppState app;

  @override
  State<RoutinesPage> createState() => _RoutinesPageState();
}

class _RoutinesPageState extends State<RoutinesPage> {
  final _name = TextEditingController();
  final _target = TextEditingController();
  String _kind = 'showMessage';
  String? _running;
  String? _runOutput;

  @override
  void dispose() {
    _name.dispose();
    _target.dispose();
    super.dispose();
  }

  Future<void> _run(String name) async {
    setState(() {
      _running = name;
      _runOutput = null;
    });
    final result = await widget.app.routines.runRoutine(name);
    if (!mounted) return;
    setState(() {
      _running = null;
      _runOutput = result.lines.join('\n');
    });
  }

  void _save() {
    final name = _name.text.trim();
    final target = _target.text.trim();
    if (name.isEmpty || target.isEmpty) return;
    widget.app.routines.saveRoutine(
      Routine(name: name, steps: [RoutineStep(kind: _kind, target: target)]),
    );
    _name.clear();
    _target.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final routines = widget.app.routines.listRoutines();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Routines',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          if (routines.isEmpty)
            const Text('No routines yet. Save one below.')
          else
            for (final routine in routines)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        routine.name,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      for (final step in routine.steps)
                        Text('${step.kind}: ${step.target}'),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          ElevatedButton(
                            onPressed: _running == null
                                ? () => _run(routine.name)
                                : null,
                            child: Text(
                              _running == routine.name
                                  ? 'Running...'
                                  : 'Run',
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton(
                            onPressed: () {
                              widget.app.routines
                                  .deleteRoutine(routine.name);
                              setState(() {});
                            },
                            child: const Text('Delete'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          if (_runOutput != null) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_runOutput!),
              ),
            ),
          ],
          const SizedBox(height: 16),
          const Text(
            'Save a routine',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              hintText: 'Routine name',
            ),
          ),
          const SizedBox(height: 8),
          DropdownButton<String>(
            value: _kind,
            items: const [
              DropdownMenuItem(
                  value: 'showMessage', child: Text('Show a message')),
              DropdownMenuItem(
                  value: 'openApp', child: Text('Open an app')),
              DropdownMenuItem(
                  value: 'openFolder', child: Text('Open a folder')),
              DropdownMenuItem(
                  value: 'waitSeconds', child: Text('Wait (seconds)')),
            ],
            onChanged: (value) {
              if (value == null) return;
              setState(() => _kind = value);
            },
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _target,
            decoration: const InputDecoration(
              hintText: 'Message, app name, folder, or seconds',
            ),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: _save,
            child: const Text('Save routine'),
          ),
        ],
      ),
    );
  }
}
