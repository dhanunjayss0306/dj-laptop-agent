// ScreenQA flow — what happens on a hotkey press (Windows Ctrl+Alt+D),
// floating Dynamic Island tap (Android), or tapping the in-app Island.
//
// Captures the screen once per ask (never continuously), streams tokens
// live ("fake lyrics") into the Dynamic Island pill and floating cursor
// overlay, speaks the reply, and flies the fake cursor to each [POINT:].
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/worker_client.dart';
import 'app_state.dart';

/// Ask what the user wants to know about the screen (typed or spoken on
/// Android). Returns null when cancelled.
Future<String?> _askQuestion(BuildContext context, DjAppState app) async {
  final controller = TextEditingController();
  StreamSubscription<String>? partialSub;
  StreamSubscription<String>? finalSub;
  var listening = false;
  final answer = await showDialog<String>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) {
        Future<void> toggleMic() async {
          if (listening) {
            await app.voiceChannel.stopListening();
            setDialogState(() => listening = false);
            return;
          }
          partialSub ??= app.voiceChannel.onPartialResult.listen((t) {
            if (t.isNotEmpty) {
              controller.text = t;
              app.updateCompanion('listening', t);
            }
          });
          finalSub ??= app.voiceChannel.onFinalResult.listen((t) {
            setDialogState(() => listening = false);
            if (t.trim().isNotEmpty && dialogContext.mounted) {
              Navigator.of(dialogContext).pop(t.trim());
            }
          });
          setDialogState(() => listening = true);
          app.updateCompanion('listening', 'Listening...');
          final res = await app.voiceChannel.startListening();
          if (res['ok'] != true && dialogContext.mounted) {
            setDialogState(() => listening = false);
            app.updateCompanion('idle');
          }
        }

        return AlertDialog(
          title: const Text('Ask DJ about your screen'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: listening
                  ? 'Listening...'
                  : 'What do you want to know?',
              suffixIcon: Platform.isAndroid
                  ? IconButton(
                      icon: Icon(listening ? Icons.mic_off : Icons.mic),
                      onPressed: toggleMic,
                    )
                  : null,
            ),
            onSubmitted: (_) =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(controller.text.trim()),
              child: const Text('Ask'),
            ),
          ],
        );
      },
    ),
  );
  await partialSub?.cancel();
  await finalSub?.cancel();
  if (listening) {
    await app.voiceChannel.stopListening();
  }
  controller.dispose();
  if (answer == null || answer.trim().isEmpty) {
    await app.updateCompanion('idle');
    return null;
  }
  return answer.trim();
}

/// Run one ScreenQA round with live "fake lyrics" captions and cursor
/// pointing (no blocking answer modal).
Future<void> runScreenQaFlow(BuildContext context, DjAppState app) async {
  final question = await _askQuestion(context, app);
  if (question == null) return;

  var cancelled = false;
  final cancelSub = app.hotkeyChannel.onCancelPressed.listen((_) {
    cancelled = true;
    app.voiceChannel.stopSpeak();
    app.cursorChannel.hideCursor();
    app.updateCompanion('idle');
  });

  final client = app.buildWorkerClient();
  final qa = app.buildScreenQAForClient(client);
  try {
    final answer = await qa.askStreaming(
      question,
      speakAnswer: true,
      history: List<ChatMessage>.from(app.screenQaHistory),
      onCompanionUpdate: (state, text) => app.updateCompanion(state, text),
      isCancelled: () => cancelled,
    );
    if (cancelled) return;

    if (answer.modelUsed && answer.text.isNotEmpty) {
      app.screenQaHistory
        ..add(ChatMessage(role: 'user', content: question))
        ..add(ChatMessage(role: 'assistant', content: answer.text));
      if (app.screenQaHistory.length > 20) {
        app.screenQaHistory.removeRange(0, app.screenQaHistory.length - 20);
      }
    }

    await app.updateCompanion('responding', answer.text);
    // Keep captions visible briefly ("fake lyrics" fade-out), then return to idle.
    await Future<void>.delayed(const Duration(seconds: 6));
    if (!cancelled) {
      await app.updateCompanion('idle');
      await app.cursorChannel.hideCursor();
    }
  } finally {
    await cancelSub.cancel();
    client?.close();
  }
}
