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

import 'package:flutter/services.dart';

class VoiceChannel {
  VoiceChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'com.dhanunjay.dj/voice';

  final MethodChannel _channel;

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
