// Real input channel (Windows SendInput).
//
// Native side: windows/runner/dj_input_channel.cpp, channel
// 'com.dhanunjay.dj/input'. Moves the REAL mouse, clicks, and types with
// Windows SendInput.
//
// SAFETY — read this before calling:
// The native side does exactly what Dart asks and nothing more. It has no
// step limit, no stuck detection, and no show-before-click rule. All of
// that lives in Dart, in the caller: show the fake cursor first
// (CursorChannel), wait for the user to see where DJ is about to act,
// cap the number of automated steps, and stop if the screen stops
// changing. Never call these methods on a password prompt or in a password
// manager; the caller is responsible for that check.

import 'package:flutter/services.dart';

class InputChannel {
  InputChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'com.dhanunjay.dj/input';

  final MethodChannel _channel;

  /// Moves the real mouse to ([x], [y]) in virtual-screen pixels.
  /// Returns false on failure. Throws nothing.
  Future<bool> moveMouse(int x, int y) async {
    return _invoke('moveMouse', <String, dynamic>{'x': x, 'y': y});
  }

  /// Clicks a mouse button: 'left', 'right', or 'middle'.
  /// Returns false on failure or for an unknown button name.
  /// Throws nothing.
  Future<bool> click([String button = 'left']) async {
    return _invoke('click', <String, dynamic>{'button': button});
  }

  /// Types [text] as Unicode key events (KEYEVENTF_UNICODE).
  /// Returns false on failure. Throws nothing.
  Future<bool> typeText(String text) async {
    return _invoke('typeText', <String, dynamic>{'text': text});
  }

  /// Presses a key by name, e.g. 'Enter', 'Escape', 'Tab', 'Alt+Tab',
  /// 'Win', 'Ctrl+C', 'Ctrl+V', 'F5'. Names are case-insensitive; '+' joins
  /// a modifier (Ctrl, Alt, Shift, Win) with the final key. See the native
  /// key map in windows/runner/dj_input_channel.cpp for the full list.
  /// Returns false for an unknown key name. Throws nothing.
  Future<bool> pressKey(String key) async {
    return _invoke('pressKey', <String, dynamic>{'key': key});
  }

  Future<bool> _invoke(String method, [Map<String, dynamic>? args]) async {
    try {
      final Map<dynamic, dynamic>? result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>(method, args);
      return result?['ok'] == true;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }
}
