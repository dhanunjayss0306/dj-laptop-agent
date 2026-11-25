// Hotkey API — the Dart side of DJ's global hotkey.
//
// Channel 'com.dhanunjay.dj/hotkey'. A Windows native agent is
// implementing RegisterHotKey on the native side; this file defines
// the Dart calls now: 'registerHotkey' with {'hotkey': 'Ctrl+Alt+D'}
// and 'unregisterHotkey' with no arguments. The native side calls
// back into Dart with the method 'onHotkeyPressed' when the user
// presses the hotkey. Until the native side lands, nothing fires —
// the stream simply never emits, and [registerHotkey] returns false.
//
// DEFAULT HOTKEY: Ctrl+Alt+D on Windows. Configurable: pass any
// hotkey string to [registerHotkey] (e.g. 'Ctrl+Alt+J').
//
// ANDROID: there is no global hotkey on Android. The same stream is
// fed by the floating button / wake word instead — they call
// [feedPress] (or the Android native side invokes 'onHotkeyPressed'
// on this channel). The UI listens to [onHotkeyPressed] either way
// and does not need to know which one fired it.

import 'dart:async';

import 'package:flutter/services.dart';

class HotkeyService {
  HotkeyService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName) {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static const String _channelName = 'com.dhanunjay.dj/hotkey';

  /// Default hotkey on Windows.
  static const String defaultHotkey = 'Ctrl+Alt+D';

  final MethodChannel _channel;
  final _pressed = StreamController<void>.broadcast();

  /// Fires every time the hotkey is pressed (Windows), or the
  /// floating button / wake word fires (Android). Broadcast: the UI
  /// and ScreenQA can both listen.
  Stream<void> get onHotkeyPressed => _pressed.stream;

  String? _registeredHotkey;

  /// The hotkey currently registered, or null when none is.
  String? get registeredHotkey => _registeredHotkey;

  /// Register the global hotkey. Returns true when the native side
  /// accepted it. Pass [hotkey] to change it from the default.
  Future<bool> registerHotkey({String hotkey = defaultHotkey}) async {
    try {
      final Map<dynamic, dynamic>? result =
          await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'registerHotkey',
        <String, dynamic>{'hotkey': hotkey},
      );
      if (result?['ok'] == true) {
        _registeredHotkey = hotkey;
        return true;
      }
      return false;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Unregister the global hotkey. Returns true when it is gone.
  Future<bool> unregisterHotkey() async {
    try {
      final Map<dynamic, dynamic>? result =
          await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'unregisterHotkey',
      );
      if (result?['ok'] == true) {
        _registeredHotkey = null;
        return true;
      }
      return false;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Feed a press into the stream from the Android side (floating
  /// button / wake word) or from tests. Same stream as the hotkey.
  void feedPress() {
    if (!_pressed.isClosed) _pressed.add(null);
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method == 'onHotkeyPressed') {
      feedPress();
    }
  }

  void dispose() => _pressed.close();
}
