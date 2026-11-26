// Floating DJ button channel (Android only).
//
// Native side: android/app/src/main/kotlin/com/dhanunjay/dj/
// FloatingButtonHandler.kt, channel 'com.dhanunjay.dj/floatingbutton'.
// Shows a small draggable blue circle with 'DJ' text in a
// TYPE_APPLICATION_OVERLAY window, so it floats over other apps — the
// Android equivalent of the Windows global hotkey, which does not exist
// on Android. Tapping the button fires 'onHotkeyPressed' on the HOTKEY
// channel ('com.dhanunjay.dj/hotkey'), the same event the Windows global
// hotkey feeds, so an existing [HotkeyChannel] listener receives taps
// through its [HotkeyChannel.onHotkeyPressed] stream with no extra wiring.
//
// The button is hidden while DJ's own app is in the foreground (there is
// no point showing it over DJ itself) and reappears automatically when
// DJ goes to the background — the native side tracks that, so Dart only
// needs to call [showFloatingButton] once (for example at startup) and
// [hideFloatingButton] when the feature is turned off. It needs
// "Display over other apps", the same permission as the cursor overlay;
// without it every call returns false.
//
// Dragging the button moves it; only the button's own small area is
// touchable, so it never blocks touches elsewhere on screen.

import 'package:flutter/services.dart';

class FloatingButtonChannel {
  FloatingButtonChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'com.dhanunjay.dj/floatingbutton';

  final MethodChannel _channel;

  /// Shows the floating DJ button. It appears at once when DJ is in the
  /// background, or automatically as soon as DJ goes to the background
  /// when DJ is currently in the foreground. Returns false when the
  /// overlay permission is not granted. Throws nothing.
  Future<bool> showFloatingButton() async {
    return _invoke('showFloatingButton');
  }

  /// Hides the floating DJ button. Always returns true unless the
  /// channel itself fails. Throws nothing.
  Future<bool> hideFloatingButton() async {
    return _invoke('hideFloatingButton');
  }

  /// Shows or hides the floating DJ button by flag. Same as calling
  /// [showFloatingButton] or [hideFloatingButton]. Returns false when
  /// showing was requested but the overlay permission is not granted.
  /// Throws nothing.
  Future<bool> setFloatingButtonVisible(bool visible) async {
    return _invoke('setFloatingButtonVisible', <String, dynamic>{
      'visible': visible,
    });
  }

  /// Updates the Android Dynamic Island pill state ('idle', 'listening',
  /// 'thinking', 'responding') and live caption text. No-op on Windows.
  Future<bool> setIslandState(String state, [String text = '']) async {
    return _invoke('setIslandState', <String, dynamic>{
      'state': state,
      'text': text,
    });
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
