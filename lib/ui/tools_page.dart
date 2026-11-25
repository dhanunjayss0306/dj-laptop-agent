// Tools page: Tutor mode, the integrations list with connect
// status, and walkthroughs. Tutor and the walkthrough engine are
// the existing feature classes; this page only drives them.
import 'dart:async';

import 'package:flutter/material.dart';

import '../features/tutor.dart';
import '../features/walkthrough.dart';
import 'app_state.dart';

class ToolsPage extends StatefulWidget {
  const ToolsPage({super.key, required this.app});

  final DjAppState app;

  @override
  State<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends State<ToolsPage> {
  final _appName = TextEditingController(text: 'Chrome');
  final _question = TextEditingController();
  StreamSubscription<WalkthroughState>? _sub;
  bool _tutorEnabled = false;
  bool _tutorBusy = false;
  String? _tutorText;

  @override
  void initState() {
    super.initState();
    _sub = widget.app.walkthroughEngine.updates.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _appName.dispose();
    _question.dispose();
    super.dispose();
  }

  Future<void> _explain() async {
    final appName = _appName.text.trim();
    final question = _question.text.trim();
    if (appName.isEmpty || question.isEmpty) return;
    setState(() {
      _tutorBusy = true;
      _tutorText = null;
    });
    // One WorkerClient for this one ask: buildScreenQA() would create
    // one that nobody closes, leaking its HttpClient on every tap.
    // The client is closed in the finally below, whatever happens.
    final client = widget.app.buildWorkerClient();
    final tutor = Tutor(
      screenQA: widget.app.buildScreenQAForClient(client),
      walkthrough: widget.app.walkthroughEngine,
      enabled: _tutorEnabled,
    );
    try {
      final explanation = await tutor.explainFromScreen(appName, question);
      if (!mounted) return;
      setState(() {
        _tutorBusy = false;
        _tutorText = explanation.text;
      });
      if (explanation.lesson != null) {
        await tutor.startLesson(explanation.lesson!);
      }
    } catch (e) {
      // A failure must not leave the Explain button stuck on
      // "Please wait..." — report it plainly instead.
      if (!mounted) return;
      setState(() {
        _tutorBusy = false;
        _tutorText = 'Something went wrong: $e';
      });
    } finally {
      client?.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final engine = widget.app.walkthroughEngine;
    final step = engine.currentStep;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Tools',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          const Text(
            'Tutor',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Tutoring mode: DJ explains one button at a time, '
                  'in plain words.',
                ),
              ),
              Switch(
                value: _tutorEnabled,
                onChanged: (value) =>
                    setState(() => _tutorEnabled = value),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _appName,
            decoration: const InputDecoration(
              hintText: 'App to learn, for example Chrome',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _question,
            decoration: const InputDecoration(
              hintText: 'What do you want to learn?',
            ),
            onSubmitted: (_) => _explain(),
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: _tutorBusy ? null : _explain,
            child: Text(_tutorBusy ? 'Please wait...' : 'Explain'),
          ),
          if (_tutorText != null) ...[
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_tutorText!),
              ),
            ),
          ],
          const SizedBox(height: 16),
          const Text(
            'Integrations',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          for (final integration in widget.app.integrations.list())
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      integration.name,
                      style:
                          const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(integration.description),
                    const SizedBox(height: 4),
                    Text(
                      integration.isConnected
                          ? 'Connected'
                          : 'Not connected',
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        if (!integration.isConnected)
                          OutlinedButton(
                            onPressed: () async {
                              final messenger =
                                  ScaffoldMessenger.of(context);
                              final ok = await integration.connect();
                              if (!mounted) return;
                              setState(() {});
                              messenger.showSnackBar(
                                SnackBar(
                                  content: Text(
                                    ok
                                        ? '${integration.name} connected.'
                                        : '${integration.name} is not connected yet.',
                                  ),
                                ),
                              );
                            },
                            child: const Text('Connect'),
                          )
                        else
                          OutlinedButton(
                            onPressed: () async {
                              await integration.disconnect();
                              if (!mounted) return;
                              setState(() {});
                            },
                            child: const Text('Disconnect'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 16),
          const Text(
            'Walkthroughs',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          const Text(
            'DJ points at each step on your screen. You do the '
            'clicking.',
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              ElevatedButton(
                onPressed: engine.isRunning
                    ? null
                    : () => engine.start(Walkthrough.exampleChromeSearch()),
                child: const Text('Start example walkthrough'),
              ),
              if (engine.isRunning) ...[
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () => engine.cancel(),
                  child: const Text('Cancel'),
                ),
              ],
            ],
          ),
          if (engine.isRunning && step != null) ...[
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(engine.progressLabel),
                    const SizedBox(height: 4),
                    Text(
                      step.title,
                      style:
                          const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(step.instruction),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        OutlinedButton(
                          onPressed: () => engine.previous(),
                          child: const Text('Back'),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: () => engine.next(),
                          child: const Text('Next'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
