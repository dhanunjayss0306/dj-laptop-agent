// Annotations — circles, arrows, highlights and text labels drawn on
// the screen so DJ can point the way, not just show the cursor triangle.
//
// DJ blue #0071E3 for all drawing.
//
// Native side: a Windows native agent is adding `annotate` and
// `clearAnnotations` to the cursor channel ('com.dhanunjay.dj/cursor').
// This file defines the Dart calls now: method 'annotate' with a list of
// annotation maps, and 'clearAnnotations' with no arguments. Until the
// native side lands, both calls return false and nothing is drawn — the
// controller never throws, and the walkthrough/tutor still work (they
// fall back to the fake cursor alone).
//
// Annotations live in memory only. Nothing is written to disk.

import 'package:flutter/services.dart';

/// DJ blue, used for every annotation. ARGB int for the channel.
const int djBlueArgb = 0xFF0071E3;

/// One drawable annotation. [toMap] is the exact map sent over the
/// channel; keep the keys stable — the native side reads them.
sealed class Annotation {
  const Annotation({this.colorArgb = djBlueArgb});
  final int colorArgb;
  String get type;
  Map<String, dynamic> toMap();
}

class CircleAnnotation extends Annotation {
  const CircleAnnotation({
    required this.x,
    required this.y,
    required this.r,
    super.colorArgb,
  });
  final int x;
  final int y;
  final int r;
  @override
  String get type => 'circle';
  @override
  Map<String, dynamic> toMap() =>
      {'type': type, 'x': x, 'y': y, 'r': r, 'color': colorArgb};
}

class ArrowAnnotation extends Annotation {
  const ArrowAnnotation({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    super.colorArgb,
  });
  final int x1;
  final int y1;
  final int x2;
  final int y2;
  @override
  String get type => 'arrow';
  @override
  Map<String, dynamic> toMap() => {
        'type': type,
        'x1': x1,
        'y1': y1,
        'x2': x2,
        'y2': y2,
        'color': colorArgb,
      };
}

class HighlightAnnotation extends Annotation {
  const HighlightAnnotation({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    super.colorArgb,
  });
  final int x;
  final int y;
  final int w;
  final int h;
  @override
  String get type => 'highlight';
  @override
  Map<String, dynamic> toMap() => {
        'type': type,
        'x': x,
        'y': y,
        'w': w,
        'h': h,
        'color': colorArgb,
      };
}

class TextAnnotation extends Annotation {
  const TextAnnotation({
    required this.x,
    required this.y,
    required this.text,
    super.colorArgb,
  });
  final int x;
  final int y;
  final String text;
  @override
  String get type => 'text';
  @override
  Map<String, dynamic> toMap() =>
      {'type': type, 'x': x, 'y': y, 'text': text, 'color': colorArgb};
}

/// Owns the current annotations and pushes them to the native overlay.
///
/// Every draw call re-sends the whole list (the native side redraws
/// from the list), so the Dart list is the single source of truth.
class AnnotationController {
  AnnotationController({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'com.dhanunjay.dj/cursor';

  final MethodChannel _channel;
  final List<Annotation> _annotations = [];

  /// The annotations currently on screen, in draw order.
  List<Annotation> get annotations => List.unmodifiable(_annotations);

  Future<bool> drawCircle(int x, int y, int r) =>
      _add(CircleAnnotation(x: x, y: y, r: r));

  Future<bool> drawArrow(int x1, int y1, int x2, int y2) =>
      _add(ArrowAnnotation(x1: x1, y1: y1, x2: x2, y2: y2));

  Future<bool> highlight(int x, int y, int w, int h) =>
      _add(HighlightAnnotation(x: x, y: y, w: w, h: h));

  Future<bool> drawText(int x, int y, String text) =>
      _add(TextAnnotation(x: x, y: y, text: text));

  /// Adds one annotation without drawing yet (for building a set).
  void add(Annotation annotation) => _annotations.add(annotation);

  /// Pushes the current list to the native overlay.
  Future<bool> show() => _push();

  /// Removes every annotation, on screen and in memory.
  Future<bool> clearAll() async {
    _annotations.clear();
    try {
      final Map<dynamic, dynamic>? result =
          await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'clearAnnotations',
      );
      return result?['ok'] == true;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _add(Annotation annotation) async {
    _annotations.add(annotation);
    return _push();
  }

  Future<bool> _push() async {
    try {
      final Map<dynamic, dynamic>? result =
          await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'annotate',
        <String, dynamic>{
          'annotations': _annotations.map((a) => a.toMap()).toList(),
        },
      );
      return result?['ok'] == true;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }
}
