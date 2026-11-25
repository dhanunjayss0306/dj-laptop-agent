// ScreenQA flow — what happens on a hotkey press (Windows
// Ctrl+Alt+D) or a floating-button tap (Android).
//
// The screen is captured ONLY here, once per press, never
// continuously. The user is asked what they want to know, the
// screenshot + question go through the saved Cloud settings
// (Worker URL + provider from dj_cloud.json), the plain-text answer
// is shown, and ScreenQA moves the fake cursor to the first
// [POINT:] tag. When no Worker URL is set or no model is up,
// ScreenQA says so plainly and falls back to its Core-only path.
import 'package:flutter/material.dart';

import 'app_state.dart';

/// Ask what the user wants to know about the screen. Null when the
/// user cancels or asks nothing.
Future<String?> _askQuestion(BuildContext context) async {
  final controller = TextEditingController();
  final answer = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Ask about your screen'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: 'What do you want to know?',
        ),
        onSubmitted: (_) =>
            Navigator.of(context).pop(controller.text.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () =>
              Navigator.of(context).pop(controller.text.trim()),
          child: const Text('Ask'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (answer == null || answer.trim().isEmpty) return null;
  return answer.trim();
}

/// Run one ScreenQA round: question dialog, capture once, answer
/// dialog. Safe to call from a hotkey listener; it does nothing when
/// the user cancels.
Future<void> runScreenQaFlow(BuildContext context, DjAppState app) async {
  final question = await _askQuestion(context);
  if (question == null) return;
  if (!context.mounted) return;

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => const AlertDialog(
      content: Row(
        children: [
          CircularProgressIndicator(),
          SizedBox(width: 16),
          Expanded(child: Text('Looking at your screen...')),
        ],
      ),
    ),
  );

  final client = app.buildWorkerClient();
  final qa = app.buildScreenQAForClient(client);
  final answer = await qa.ask(question);
  client?.close();

  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).pop();

  final lines = <String>[answer.text];
  if (answer.points.isNotEmpty) {
    final first = answer.points.first;
    lines.add(
      'Pointed at: ${first.label.isEmpty ? 'here' : first.label} '
      '(${first.x}, ${first.y}).',
    );
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Screen answer'),
      content: SingleChildScrollView(
        child: Text(lines.join('\n\n')),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
