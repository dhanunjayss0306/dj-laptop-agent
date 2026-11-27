// Hey DJ wake-word matcher & passive listener (HeyClicky / Hey Bixby style).
//
// Extracts wake phrases ("Hey DJ", "OK DJ", "DJ ...") permissively from
// live partial/final speech transcripts, stripping punctuation and filler so
// "Hey, DJ! Open Chrome." immediately becomes `command: "Open Chrome"`.
//
// On Android, when hands-free wake-word mode is enabled, runs an event-driven
// continuous SpeechRecognizer loop using VoiceChannel and pauses cleanly while
// active ScreenQA recording or TTS is in progress.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../platform/voice_channel.dart';

class WakeWordMatch {
  const WakeWordMatch({
    required this.matched,
    required this.wakePhrase,
    required this.command,
  });

  final bool matched;
  final String wakePhrase;
  final String command;
}

final List<RegExp> _wakePatterns = [
  // Multi-word greetings anywhere near the start (allow filler words before).
  RegExp(
    r'^(?:please\s+|um\s+|uh\s+)*(?:hey|hi|ok|okay)\s*,?\s*(?:deejay|d\.?\s*j\.?)\b[\s,.:;!?-]*',
    caseSensitive: false,
  ),
  // Direct "DJ, ..." at the start of an utterance.
  RegExp(
    r'^(?:deejay|d\.?\s*j\.?)\b[\s,.:;!?-]+',
    caseSensitive: false,
  ),
  // Embedded wake phrase mid-sentence ("... wait hey dj open settings").
  RegExp(
    r'\b(?:hey|ok|okay)\s*,?\s*(?:deejay|d\.?\s*j\.?)\b[\s,.:;!?-]*',
    caseSensitive: false,
  ),
];

/// Extract whether [transcript] invokes DJ and return the trailing command.
WakeWordMatch extractWakeCommand(String transcript) {
  final raw = transcript.trim();
  if (raw.isEmpty) {
    return const WakeWordMatch(matched: false, wakePhrase: '', command: '');
  }
  for (final pattern in _wakePatterns) {
    final match = pattern.firstMatch(raw);
    if (match != null) {
      final wake = match.group(0)!.trim();
      var rest = raw.substring(match.end).trim();
      rest = rest
          .replaceFirst(RegExp(r'^(?:please|can you|could you)\s+', caseSensitive: false), '')
          .trim();
      return WakeWordMatch(matched: true, wakePhrase: wake, command: rest);
    }
  }
  return const WakeWordMatch(matched: false, wakePhrase: '', command: '');
}

/// Optional hands-free "Hey DJ" passive wake-word controller.
/// Uses Android's built-in SpeechRecognizer on-device loop when enabled.
class WakeWordController {
  WakeWordController({
    required VoiceChannel voiceChannel,
    required Future<void> Function(String command) onWakeCommand,
  })  : _voice = voiceChannel,
        _onWakeCommand = onWakeCommand;

  final VoiceChannel _voice;
  final Future<void> Function(String command) _onWakeCommand;

  final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);
  bool _paused = false;
  bool _disposed = false;
  bool _loopBusy = false;
  StreamSubscription<String>? _finalSub;
  StreamSubscription<String>? _errSub;
  Timer? _restartTimer;

  bool get isSupported => Platform.isAndroid;

  Future<void> setEnabled(bool value) async {
    if (_disposed) return;
    enabled.value = value;
    _restartTimer?.cancel();
    if (!value) {
      await _teardownListeners();
      return;
    }
    if (!isSupported) return;
    _attachListeners();
    if (!_paused) {
      _scheduleRestart(const Duration(milliseconds: 120));
    }
  }

  /// Pause passive wake detection while an active voice command / ScreenQA
  /// round owns the microphone.
  void setPaused(bool paused) {
    _paused = paused;
    _restartTimer?.cancel();
    if (!paused && enabled.value && isSupported && !_disposed) {
      _scheduleRestart(const Duration(milliseconds: 350));
    }
  }

  void _attachListeners() {
    _finalSub ??= _voice.onFinalResult.listen((text) async {
      if (!enabled.value || _paused || _disposed || _loopBusy) return;
      final hit = extractWakeCommand(text);
      if (hit.matched) {
        _loopBusy = true;
        try {
          await _onWakeCommand(hit.command);
        } finally {
          _loopBusy = false;
        }
      }
      if (enabled.value && !_paused && !_disposed) {
        _scheduleRestart(const Duration(milliseconds: 250));
      }
    });
    _errSub ??= _voice.onSpeechError.listen((_) {
      if (enabled.value && !_paused && !_disposed && !_loopBusy) {
        _scheduleRestart(const Duration(milliseconds: 900));
      }
    });
  }

  void _scheduleRestart(Duration delay) {
    _restartTimer?.cancel();
    _restartTimer = Timer(delay, () async {
      if (!enabled.value || _paused || _disposed || _loopBusy) return;
      await _voice.startListening();
    });
  }

  Future<void> _teardownListeners() async {
    await _finalSub?.cancel();
    _finalSub = null;
    await _errSub?.cancel();
    _errSub = null;
    await _voice.stopListening();
  }

  Future<void> dispose() async {
    _disposed = true;
    enabled.value = false;
    _restartTimer?.cancel();
    await _teardownListeners();
    enabled.dispose();
  }
}
