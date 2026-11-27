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

import '../core/brain.dart';
import '../core/worker_client.dart';
import '../features/agent_mode.dart';
import '../features/wake_word.dart';
import 'app_state.dart';

enum VoiceRouteKind { chat, agent, screen }

/// Classify whether a spoken query is an instant local/chat command, an
/// autonomous AgentMode task, or a ScreenQA visual question ("Hey Clicky /
/// Hey Bixby" hybrid routing).
VoiceRouteKind classifyVoiceCommand(
  String rawText, [
  List<String> knownFolders = const [],
]) {
  final text = rawText.trim();
  if (text.isEmpty) return VoiceRouteKind.screen;
  final low = text.toLowerCase();
  if (low.startsWith('agent ') || low.startsWith('dj agent ')) {
    return VoiceRouteKind.agent;
  }
  final action = BrainService().decide(text, knownFolders);
  switch (action.action) {
    case 'openApp':
    case 'openFolder':
    case 'organize':
    case 'duplicates':
    case 'list':
    case 'summarize':
      return VoiceRouteKind.chat;
    case 'help':
      return (low == 'help' ||
              low.contains('what can you do') ||
              low.contains('help me'))
          ? VoiceRouteKind.chat
          : VoiceRouteKind.screen;
    case 'search':
      final isExplicitFileCmd = RegExp(
        r'^(?:find|search|look for|locate|open)\b',
        caseSensitive: false,
      ).hasMatch(low);
      final isVisualHint = low.contains('screen') ||
          low.contains('this') ||
          low.contains('here') ||
          low.contains('click') ||
          low.contains('point') ||
          low.endsWith('?');
      return (isExplicitFileCmd && !isVisualHint)
          ? VoiceRouteKind.chat
          : VoiceRouteKind.screen;
    default:
      return VoiceRouteKind.screen;
  }
}

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

/// Run one voice-first "Hey DJ" round: listens (unless [initialCommand]
/// was captured by passive wake-word), routes instant commands & agent tasks
/// directly without slow vision captures, or streams live "fake lyrics" +
/// cursor pointers for screen questions. Every turn also syncs to Chat.
Future<void> runScreenQaFlow(
  BuildContext context,
  DjAppState app, {
  String? initialCommand,
}) async {
  app.wakeWord.setPaused(true);
  await app.voiceChannel.stopSpeak();
  final client = app.buildWorkerClient();

  String? question = initialCommand?.trim();
  try {
    if (question == null || question.isEmpty) {
      final voice = await _listenVoiceQuestion(app, client);
      if (voice.cancelled) {
        await app.updateCompanion('idle');
        return;
      }
      question = voice.transcript;
    }
    if (question == null || question.isEmpty) {
      if (!context.mounted) return;
      question = await _askQuestionDialog(context, app);
    }
    if (question == null || question.isEmpty) return;

    final wake = extractWakeCommand(question);
    if (wake.matched) {
      if (wake.command.isEmpty) {
        if (!context.mounted) return;
        final followUp = await _askQuestionDialog(context, app);
        if (followUp == null || followUp.isEmpty) return;
        question = followUp;
      } else {
        question = wake.command;
      }
    }

    var cancelled = false;
    final cancelSub = app.hotkeyChannel.onCancelPressed.listen((_) {
      cancelled = true;
      app.voiceChannel.stopSpeak();
      app.cursorChannel.hideCursor();
      app.updateCompanion('idle');
    });

    final knownFolders =
        app.indexer.listFolders().map((f) => f.name).toList();
    final route = classifyVoiceCommand(question, knownFolders);
    try {
      final speakAloud = app.config.value.speakScreenAnswers ?? false;

      if (route == VoiceRouteKind.agent) {
        final task = question
            .replaceFirst(
              RegExp(r'^(?:dj\s+)?agent\s+', caseSensitive: false),
              '',
            )
            .trim();
        await app.updateCompanion('thinking', 'Running: $task');
        late final StreamSubscription<AgentProgress> stepSub;
        stepSub = app.agentMode.updates.listen((p) {
          if (!cancelled) {
            unawaited(app.updateCompanion('thinking', p.description));
          }
        });
        AgentTaskResult result;
        try {
          result = await app.agentMode.run(task);
        } finally {
          await stepSub.cancel();
        }
        if (cancelled) return;
        app.postVoiceTurn(question, result.answer);
        await app.updateCompanion('responding', result.answer);
        if (speakAloud && result.answer.isNotEmpty) {
          await app.speakReply(result.answer, client: client);
        }
        await Future<void>.delayed(Duration(seconds: speakAloud ? 5 : 7));
        if (!cancelled) {
          await app.updateCompanion('idle');
          if (!app.companionFollow.value) await app.cursorChannel.hideCursor();
        }
        return;
      }

      if (route == VoiceRouteKind.chat) {
        await app.updateCompanion('thinking', question);
        final response = await app.chat.handle(question);
        if (cancelled) return;
        app.postVoiceTurn(question, response.text, response);
        await app.updateCompanion('responding', response.text);
        if (speakAloud && response.text.isNotEmpty) {
          await app.speakReply(response.text, client: client);
        }
        await Future<void>.delayed(Duration(seconds: speakAloud ? 5 : 6));
        if (!cancelled) {
          await app.updateCompanion('idle');
          if (!app.companionFollow.value) await app.cursorChannel.hideCursor();
        }
        return;
      }

      final qa = app.buildScreenQAForClient(client);
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
      if (answer.text.isNotEmpty) {
        app.postVoiceTurn(question, answer.text);
      }

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
    app.wakeWord.setPaused(false);
    client?.close();
  }
}
