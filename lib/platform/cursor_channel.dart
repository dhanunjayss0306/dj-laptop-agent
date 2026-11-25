// Fake cursor overlay channel (Windows).
//
// Native side: windows/runner/dj_cursor_channel.cpp, channel
// 'com.dhanunjay.dj/cursor'. Draws a small blue (DJ blue #0071E3) cursor
// marker — a triangle plus a label bubble — in a transparent,
// always-on-top, click-through layered window. It NEVER moves the real
// mouse and NEVER intercepts clicks (WS_EX_TRANSPARENT).
//
// The same window also draws screen annotations (see [annotate]):
// circles, arrows, highlight rects and text labels, in the same DJ blue,
// on top of everything, still click-through. Annotations persist until
// [clearAnnotations] or [hideCursor].
//
// Use it to show the user where DJ is about to act, before the real input
// channel does anything. The safety rules (step limit, stuck detection,
// show-before-click) live in Dart, in the caller.

import 'package:flutter/services.dart';

class CursorChannel {
  CursorChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'com.dhanunjay.dj/cursor';

  final MethodChannel _channel;

  /// Shows the fake cursor at ([x], [y]) in virtual-screen pixels, with an
  /// optional [label] in the bubble. Returns false when the overlay could
  /// not be shown. Throws nothing.
  Future<bool> showCursor(int x, int y, [String label = '']) async {
    return _invoke('showCursor', <String, dynamic>{
      'x': x,
      'y': y,
      'label': label,
    });
  }

  /// Slides the fake cursor smoothly (~300 ms) to ([x], [y]) and updates
  /// the label. Returns false when the overlay is not showing.
  /// Throws nothing.
  Future<bool> moveCursor(int x, int y, [String label = '']) async {
    return _invoke('moveCursor', <String, dynamic>{
      'x': x,
      'y': y,
      'label': label,
    });
  }

  /// Hides the fake cursor. Also clears any annotations (they persist
  /// until [clearAnnotations] or this call). Always returns true unless
  /// the channel itself fails. Throws nothing.
  Future<bool> hideCursor() async {
    return _invoke('hideCursor');
  }

  /// Draws [annotations] on the same overlay window as the cursor, in DJ
  /// blue, on top of everything, click-through. Each map is one shape:
  /// `{'type': 'circle', 'x': x, 'y': y, 'r': r}` (outline circle),
  /// `{'type': 'arrow', 'x1': x1, 'y1': y1, 'x2': x2, 'y2': y2}`
  /// (line + arrowhead),
  /// `{'type': 'rect', 'x': x, 'y': y, 'w': w, 'h': h}` (translucent
  /// blue fill + solid border), or
  /// `{'type': 'text', 'x': x, 'y': y, 'text': text}` (small label
  /// bubble). Coordinates are virtual-screen pixels. Replaces any
  /// annotations already shown, and shows them even when the cursor
  /// itself is hidden. An empty list clears. Returns false on failure.
  /// Throws nothing.
  Future<bool> annotate(List<Map<String, dynamic>> annotations) async {
    return _invoke('annotate', <String, dynamic>{
      'annotations': annotations,
    });
  }

  /// Clears all annotations. If the cursor is showing it stays showing;
  /// otherwise the overlay hides. Returns false on failure.
  /// Throws nothing.
  Future<bool> clearAnnotations() async {
    return _invoke('clearAnnotations');
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
