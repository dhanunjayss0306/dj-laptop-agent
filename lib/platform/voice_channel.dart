// Voice channel (Windows).
//
// Native side: windows/runner/dj_voice_channel.cpp, channel
// 'com.dhanunjay.dj/voice'. Two independent pieces:
//
// 1. Text-to-speech via Windows SAPI (ISpVoice). Fully implemented in C++,
//    works offline, no downloads. [speak] / [stopSpeak].
// 2. Speech-to-text via a local whisper.cpp sidecar. [startWhisper] launches
//    whisper-server (if a whisper binary + ggml model exist next to the app)
//    and [transcribe] POSTs audio to http://127.0.0.1:8080/inference.
//    When no whisper binary/model is present the native side returns
//    ok:false with 'whisper not installed — see WINDOWS-BUILD.md'.
//    DJ NEVER fakes a transcript: a missing sidecar is a plain failure,
//    never invented text.
//
// Voice is new work, not a port: the Electron app had no working voice
// assistant (PORTING-SPEC.md §4).

import 'dart:async';

import 'package:flutter/services.dart';

class VoiceChannel {
  VoiceChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName) {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static const String _channelName = 'com.dhanunjay.dj/voice';

  final MethodChannel _channel;
  final StreamController<String> _partialController =
      StreamController<String>.broadcast();
  final StreamController<String> _finalController =
      StreamController<String>.broadcast();
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();
  final StreamController<bool> _listeningController =
      StreamController<bool>.broadcast();
  final StreamController<double> _levelController =
      StreamController<double>.broadcast();
  final StreamController<void> _silenceController =
      StreamController<void>.broadcast();

  /// Live partial speech results from Android SpeechRecognizer.
  Stream<String> get onPartialResult => _partialController.stream;

  /// Final speech transcript from Android SpeechRecognizer.
  Stream<String> get onFinalResult => _finalController.stream;

  /// Speech recognition error messages.
  Stream<String> get onSpeechError => _errorController.stream;

  /// Listening state changes (true = mic open, false = stopped).
  Stream<bool> get onListeningChanged => _listeningController.stream;

  /// Normalized mic RMS audio level (0.0..1.0) while listening.
  Stream<double> get onAudioLevel => _levelController.stream;

  /// Emits when Windows detects end-of-utterance silence after speech.
  Stream<void> get onSilenceDetected => _silenceController.stream;

  Future<void> _handleNativeCall(MethodCall call) async {
    final args = call.arguments;
    String text() =>
        args is Map ? (args['text']?.toString() ?? '') : '';
    String message() =>
        args is Map ? (args['message']?.toString() ?? '') : '';
    switch (call.method) {
      case 'onPartialResult':
        if (!_partialController.isClosed) _partialController.add(text());
      case 'onFinalResult':
        if (!_finalController.isClosed) _finalController.add(text());
      case 'onSpeechError':
        if (!_errorController.isClosed) _errorController.add(message());
      case 'onListeningStarted':
        if (!_listeningController.isClosed) _listeningController.add(true);
      case 'onListeningStopped':
        if (!_listeningController.isClosed) _listeningController.add(false);
      case 'onAudioLevel':
        final raw = args is Map ? args['level'] : null;
        final level = raw is num ? raw.toDouble() : 0.0;
        if (!_levelController.isClosed) _levelController.add(level);
      case 'onSilenceDetected':
        if (!_silenceController.isClosed) _silenceController.add(null);
    }
  }

  /// Starts built-in speech recognition (Android) or mic capture (Windows).
  Future<Map<String, dynamic>> startListening() => _invoke('startListening');

  /// Stops speech recognition / mic capture (returns `wavBase64` on Windows).
  Future<Map<String, dynamic>> stopListening() => _invoke('stopListening');

  /// Plays an in-memory WAV buffer (`wavBase64`).
  Future<Map<String, dynamic>> playAudioBase64(String wavBase64) =>
      _invoke('playAudio', <String, dynamic>{'wavBase64': wavBase64});

  Future<void> dispose() async {
    await _partialController.close();
    await _finalController.close();
    await _errorController.close();
    await _listeningController.close();
    await _levelController.close();
    await _silenceController.close();
  }

  /// Speaks [text] with Windows SAPI (ISpVoice), offline. Returns
  /// {'ok': true} when speaking started, {'ok': false, 'message': ...}
  /// when SAPI is unavailable. Never throws.
  Future<Map<String, dynamic>> speak(String text) {
    return _invoke('speak', <String, dynamic>{'text': text});
  }

  /// Stops any in-progress speech. Never throws.
  Future<Map<String, dynamic>> stopSpeak() {
    return _invoke('stopSpeak');
  }

  /// Starts the local whisper.cpp whisper-server sidecar with the ggml
  /// model at [modelPath]. The whisper-server binary must sit next to the
  /// app exe (see windows/README-DJ.md). Returns
  /// {'ok': false, 'message': 'whisper not installed — see WINDOWS-BUILD.md'}
  /// when the binary or the model file is missing. Never throws.
  Future<Map<String, dynamic>> startWhisper(String modelPath) {
    return _invoke('startWhisper', <String, dynamic>{'modelPath': modelPath});
  }

  /// Transcribes the audio file at [audioPath] (wav, 16 kHz mono works
  /// best) through the running whisper-server and returns
  /// ok true with a 'text' entry holding the transcript. When the server
  /// is not running or the file is missing, returns ok false with a
  /// 'message' entry. Never throws, never invents a transcript.
  Future<Map<String, dynamic>> transcribe(String audioPath) {
    return _invoke('transcribe', <String, dynamic>{'audioPath': audioPath});
  }

  /// Reports whether the whisper sidecar binary and the model at
  /// [modelPath] exist, and whether the server process is running.
  /// Never throws.
  Future<Map<String, dynamic>> whisperStatus([String modelPath = '']) {
    return _invoke(
      'whisperStatus',
      <String, dynamic>{'modelPath': modelPath},
    );
  }

  Future<Map<String, dynamic>> _invoke(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    try {
      final Map<dynamic, dynamic>? result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>(method, arguments);
      if (result == null) {
        return <String, dynamic>{
          'ok': false,
          'message': 'No reply from Windows for $method.',
        };
      }
      final Map<String, dynamic> out = <String, dynamic>{};
      for (final MapEntry<dynamic, dynamic> entry in result.entries) {
        out[entry.key.toString()] = entry.value;
      }
      out.putIfAbsent('ok', () => true);
      return out;
    } on PlatformException catch (e) {
      return <String, dynamic>{
        'ok': false,
        'message': e.message ?? e.toString(),
      };
    } catch (e) {
      return <String, dynamic>{'ok': false, 'message': e.toString()};
    }
  }
}
