// Global hotkey channel (Windows).
//
// Native side: windows/runner/dj_hotkey.h/.cpp, channel
// 'com.dhanunjay.dj/hotkey'. Registers a system-wide hotkey with Win32
// RegisterHotKey on the runner window, so it fires even when DJ is not
// the focused window. The native side invokes 'onHotkeyPressed' on this
// channel when the hotkey is pressed; this class exposes it as the
// [onHotkeyPressed] broadcast stream.
//
// Default hotkey is Ctrl+Alt+D (vk 0x44, 'D'). Pass different modifiers
// or a different virtual-key code to [registerHotkey] to change it.
// Registering replaces any hotkey already registered. If the hotkey is
// already taken by another app, [registerHotkey] returns false and DJ
// never steals it.
//
// Create one instance and keep it for the app's lifetime; creating a
// second instance replaces the native-call handler of the first.

import 'dart:async';

import 'package:flutter/services.dart';

class HotkeyChannel {
  HotkeyChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName) {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static const String _channelName = 'com.dhanunjay.dj/hotkey';

  /// Default hotkey: Ctrl+Alt+D. [vk] is a Windows virtual-key code
  /// (0x44 is 'D').
  static const int defaultVk = 0x44;

  /// Privacy Screen override hotkey: Ctrl+Alt+P (vk 0x50, 'P').
  /// A separate native hotkey id (2), so registering it never replaces
  /// Ctrl+Alt+D and registering Ctrl+Alt+D never replaces it.
  static const int privacyVk = 0x50;

  final MethodChannel _channel;
  final StreamController<void> _pressedController =
      StreamController<void>.broadcast();
  final StreamController<void> _privacyPressedController =
      StreamController<void>.broadcast();

  /// Fires once per hotkey press, even when DJ is not the focused window.
  /// The native side sends no repeat events while the keys are held down.
  Stream<void> get onHotkeyPressed => _pressedController.stream;

  /// Fires once per Ctrl+Alt+P press, even when the screen is blacked
  /// out and DJ does not have focus. The Privacy Screen controller
  /// listens to this and toggles its override.
  Stream<void> get onPrivacyHotkeyPressed =>
      _privacyPressedController.stream;

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method == 'onHotkeyPressed') {
      if (!_pressedController.isClosed) {
        _pressedController.add(null);
      }
    } else if (call.method == 'onPrivacyHotkeyPressed') {
      if (!_privacyPressedController.isClosed) {
        _privacyPressedController.add(null);
      }
    }
  }

  /// Registers the global hotkey. Defaults to Ctrl+Alt+D. Returns false
  /// when registration fails — for example when another app already uses
  /// the hotkey. Throws nothing.
  Future<bool> registerHotkey({
    bool ctrl = true,
    bool alt = true,
    bool shift = false,
    bool win = false,
    int vk = defaultVk,
  }) async {
    final List<String> modifiers = <String>[
      if (ctrl) 'ctrl',
      if (alt) 'alt',
      if (shift) 'shift',
      if (win) 'win',
    ];
    try {
      final Map<dynamic, dynamic>? result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('registerHotkey',
              <String, dynamic>{
            'modifiers': modifiers,
            'vk': vk,
          });
      return result?['ok'] == true;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Unregisters the global hotkey. Returns false only when the channel
  /// itself fails; unregistering when nothing is registered still
  /// returns true. Throws nothing.
  Future<bool> unregisterHotkey() async {
    try {
      final Map<dynamic, dynamic>? result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('unregisterHotkey');
      return result?['ok'] == true;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Registers the Privacy Screen override hotkey (Ctrl+Alt+P).
  /// Independent of [registerHotkey]: the two coexist, and one never
  /// replaces the other. Returns false when registration fails — for
  /// example when another app already uses Ctrl+Alt+P. Throws nothing.
  Future<bool> registerPrivacyHotkey({
    bool ctrl = true,
    bool alt = true,
    bool shift = false,
    bool win = false,
    int vk = privacyVk,
  }) async {
    final List<String> modifiers = <String>[
      if (ctrl) 'ctrl',
      if (alt) 'alt',
      if (shift) 'shift',
      if (win) 'win',
    ];
    try {
      final Map<dynamic, dynamic>? result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('registerPrivacyHotkey',
              <String, dynamic>{
            'modifiers': modifiers,
            'vk': vk,
          });
      return result?['ok'] == true;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Unregisters the Privacy Screen override hotkey. Returns false only
  /// when the channel itself fails. Throws nothing.
  Future<bool> unregisterPrivacyHotkey() async {
    try {
      final Map<dynamic, dynamic>? result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('unregisterPrivacyHotkey');
      return result?['ok'] == true;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Closes the [onHotkeyPressed] stream. The native hotkey stays
  /// registered until [unregisterHotkey] or the app quits.
  Future<void> dispose() async {
    await _pressedController.close();
    await _privacyPressedController.close();
  }
}
