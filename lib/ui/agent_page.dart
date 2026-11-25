// Agent page: a task box + Run. Runs AgentMode with its 15-step
// cap and shows each step as it happens, plus the final answer and
// the stop reason when the run stops early (stuck, blocked, or the
// step cap). Passwords are never typed: AgentMode refuses those
// steps and says so.
import 'dart:async';

import 'package:flutter/material.dart';

import '../features/agent_mode.dart';
import 'app_state.dart';

class AgentPage extends StatefulWidget {
  const AgentPage({super.key, required this.app});

  final DjAppState app;

  @override
  State<AgentPage> createState() => _AgentPageState();
}

class _AgentPageState extends State<AgentPage> {
  final _task = TextEditingController();
  StreamSubscription<AgentProgress>? _sub;
  final _steps = <AgentProgress>[];
  String? _result;
  String? _stoppedReason;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _sub = widget.app.agentMode.updates.listen((progress) {
      if (!mounted) return;
      setState(() => _steps.add(progress));
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _task.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final task = _task.text.trim();
    if (task.isEmpty || _running) return;
    setState(() {
      _running = true;
      _steps.clear();
      _result = null;
      _stoppedReason = null;
    });
    final result = await widget.app.agentMode.run(task);
    if (!mounted) return;
    setState(() {
      _running = false;
      _result =
          'Done: ${result.done}. Steps taken: ${result.stepsTaken}.\n${result.answer}';
      _stoppedReason = result.stoppedReason;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Agent',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          const Text(
            'DJ does the task itself, up to 15 steps. It stops if it '
            'gets stuck, and it never types passwords.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _task,
            decoration: const InputDecoration(
              hintText: 'DJ agent open Chrome',
            ),
            onSubmitted: (_) => _run(),
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: _running ? null : _run,
            child: Text(_running ? 'Running...' : 'Run'),
          ),
          const SizedBox(height: 16),
          if (_steps.isNotEmpty) ...[
            const Text(
              'Steps',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            for (final step in _steps)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  'Step ${step.stepIndex} of ${step.totalSteps}: '
                  '${step.description} (${step.status})',
                ),
              ),
            const SizedBox(height: 12),
          ],
          if (_stoppedReason != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text('Stopped: $_stoppedReason'),
              ),
            ),
          if (_result != null) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_result!),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
