// ScreenQA flow — voice-first Clicky/HeyClicky companion pipeline.
//
// Pressing Ctrl+Alt+D (Windows), tapping the Dynamic Island pill (Android),
// or tapping the voice icon immediately opens the mic with waveform
// feedback (no blocking typing dialog when voice + STT work). Captures
// the screen once per ask, streams live "fake lyrics" captions, circles &
// flies the blue cursor to each [POINT:], and speaks the reply aloud.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/worker_client.dart';
import 'app_state.dart';

/// Compact fallback prompt used only when microphone / STT is unavailable.
Future<String?> _askQuestionDialog(BuildContext context, DjAppState app) async {
  final controller = TextEditingController();
  final answer = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Ask DJ about your screen'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: 'What do you want to know?',
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
    ),
  );
  controller.dispose();
  if (answer == null || answer.trim().isEmpty) {
    await app.updateCompanion('idle');
    return null;
  }
  return answer.trim();
}

/// Listen immediately via mic (Windows WinMM + Worker STT, or Android
/// SpeechRecognizer). Returns null when cancelled, empty string when voice
/// hardware/STT isn't ready so the caller can fall back to text input.
Future<({bool cancelled, String? transcript})> _listenVoiceQuestion(
  DjAppState app,
  WorkerClient? client,
) async {
  Map<String, dynamic>? whisper;
  if (Platform.isWindows) {
    whisper = await app.voiceChannel.whisperStatus();
    if (client == null &&
        whisper['running'] != true &&
        whisper['serverFound'] != true) {
      return (cancelled: false, transcript: null);
    }
  }

  final startRes = await app.voiceChannel.startListening();
  if (startRes['ok'] != true) {
    return (cancelled: false, transcript: null);
  }

  await app.updateCompanion(
    'listening',
    Platform.isWindows
        ? 'Listening... (speak, pause or press Ctrl+Shift+Space)'
        : 'Listening...',
  );

  final done = Completer<String>();
  var androidFinal = '';
  var cancelled = false;
  var lastPartial = '';

  final levelSub = app.voiceChannel.onAudioLevel.listen((lvl) {
    app.cursorChannel.setAudioLevel(lvl);
  });
  final partialSub = app.voiceChannel.onPartialResult.listen((t) {
    if (t.isNotEmpty) {
      lastPartial = t;
      app.updateCompanion('listening', t);
    }
  });
  final finalSub = app.voiceChannel.onFinalResult.listen((t) {
    androidFinal = t.trim();
    if (!done.isCompleted) done.complete('final');
  });
  final errSub = app.voiceChannel.onSpeechError.listen((_) {
    if (!done.isCompleted) done.complete('error');
  });
  final silenceSub = app.voiceChannel.onSilenceDetected.listen((_) {
    if (!done.isCompleted) done.complete('silence');
  });
  final hotkeySub = app.hotkeyChannel.onHotkeyPressed.listen((_) {
    if (!done.isCompleted) done.complete('hotkey');
  });
  final cancelSub = app.hotkeyChannel.onCancelPressed.listen((_) {
    cancelled = true;
    if (!done.isCompleted) done.complete('cancel');
  });

  // Safety cap so the mic can never stay open forever.
  final maxTimer = Timer(const Duration(seconds: 25), () {
    if (!done.isCompleted) done.complete('timeout');
  });

  await done.future;
  maxTimer.cancel();
  await levelSub.cancel();
  await partialSub.cancel();
  await finalSub.cancel();
  await errSub.cancel();
  await silenceSub.cancel();
  await hotkeySub.cancel();
  await cancelSub.cancel();
  await app.cursorChannel.setAudioLevel(0.0);

  final stopRes = await app.voiceChannel.stopListening();
  if (cancelled) {
    return (cancelled: true, transcript: null);
  }

  if (Platform.isAndroid) {
    final spoken = androidFinal.isNotEmpty ? androidFinal : lastPartial.trim();
    return (
      cancelled: false,
      transcript: spoken.isEmpty ? null : spoken,
    );
  }

  final wavB64 = stopRes['wavBase64'] as String? ?? '';
  if (wavB64.isEmpty) {
    return (cancelled: false, transcript: null);
  }
  await app.updateCompanion('thinking', 'Transcribing...');
  if (client != null) {
    try {
      final wavBytes = base64Decode(wavB64);
      final text = await client.transcribeWav(wavBytes);
      if (text.trim().isNotEmpty) {
        return (cancelled: false, transcript: text.trim());
      }
    } catch (_) {
      // Fall through to local OpenWhisper sidecar if available.
    }
  }
  if (Platform.isWindows) {
    whisper ??= await app.voiceChannel.whisperStatus();
    if (whisper['running'] != true && whisper['serverFound'] == true) {
      final modelPath = whisper['defaultModelPath'] as String? ?? '';
      if (modelPath.isNotEmpty) {
        await app.voiceChannel.startWhisper(modelPath);
      }
    }
    final local = await app.voiceChannel.transcribeWavBytes(wavB64);
    if (local['ok'] == true) {
      final text = (local['text'] as String? ?? '').trim();
      return (cancelled: false, transcript: text.isEmpty ? null : text);
    }
  }
  return (cancelled: false, transcript: null);
}

/// Run one voice-first ScreenQA round with live "fake lyrics" captions,
/// animated cursor pointing + circles, and spoken audio reply.
Future<void> runScreenQaFlow(BuildContext context, DjAppState app) async {
  await app.voiceChannel.stopSpeak();
  final client = app.buildWorkerClient();

  String? question;
  try {
    final voice = await _listenVoiceQuestion(app, client);
    if (voice.cancelled) {
      await app.updateCompanion('idle');
      return;
    }
    question = voice.transcript;
    if (question == null || question.isEmpty) {
      if (!context.mounted) return;
      question = await _askQuestionDialog(context, app);
    }
    if (question == null || question.isEmpty) return;

    var cancelled = false;
    final cancelSub = app.hotkeyChannel.onCancelPressed.listen((_) {
      cancelled = true;
      app.voiceChannel.stopSpeak();
      app.cursorChannel.hideCursor();
      app.updateCompanion('idle');
    });

    final qa = app.buildScreenQAForClient(client);
    try {
      final answer = await qa.askStreaming(
        question,
        speakAnswer: false,
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

      final speakAloud = app.config.value.speakScreenAnswers ?? false;
      await app.updateCompanion('responding', answer.text);
      if (speakAloud && answer.text.isNotEmpty) {
        await app.speakReply(answer.text, client: client);
      }

      await Future<void>.delayed(Duration(seconds: speakAloud ? 6 : 10));
      if (!cancelled) {
        await app.updateCompanion('idle');
        await app.cursorChannel.clearAnnotations();
        if (app.companionFollow.value) {
          await app.cursorChannel.setCompanionFollow(true);
        } else {
          await app.cursorChannel.hideCursor();
        }
      }
    } finally {
      await cancelSub.cancel();
    }
  } finally {
    client?.close();
  }
}
