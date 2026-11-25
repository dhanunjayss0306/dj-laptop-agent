// Tests for lib/features/privacy_screen/camera_effects.dart.
// Design ported from SafeScreen by kv4u (MIT).
//
// Windows Studio Effects can blur the background or crop the picture
// before DJ sees a frame — either can remove a shoulder surfer. The
// camera is asked whether these are on; this file turns that answer
// into something the UI can state plainly. "Not reported" must never
// read as "off".

import 'package:dj/features/privacy_screen/camera_effects.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CameraEffects', () {
    test('unknown when nothing was reported', () {
      expect(CameraEffects.unknown.isReported, isFalse);
      expect(CameraEffects.unknown.hidesOthers, isFalse);
      expect(CameraEffects.unknown.summary, 'Not reported');
    });

    test('fromReply reads both effects', () {
      final CameraEffects effects = CameraEffects.fromReply({
        'backgroundBlur': true,
        'autoFraming': false,
      });
      expect(effects.backgroundBlur, isTrue);
      expect(effects.autoFraming, isFalse);
      expect(effects.hidesOthers, isTrue);
      expect(effects.summary, 'Background blur on');
    });

    test('auto framing alone hides others too', () {
      final CameraEffects effects = CameraEffects.fromReply({
        'backgroundBlur': false,
        'autoFraming': true,
      });
      expect(effects.hidesOthers, isTrue);
      expect(effects.summary, 'Auto framing on');
    });

    test('both on is reported together', () {
      final CameraEffects effects = CameraEffects.fromReply({
        'backgroundBlur': true,
        'autoFraming': true,
      });
      expect(effects.summary, 'Blur + framing on');
    });

    test('both off reads "None" — only when both were answered', () {
      final CameraEffects effects = CameraEffects.fromReply({
        'backgroundBlur': false,
        'autoFraming': false,
      });
      expect(effects.hidesOthers, isFalse);
      expect(effects.summary, 'None');
    });

    test('one answer is not enough to claim "None"', () {
      expect(
        CameraEffects.fromReply({'backgroundBlur': false}).summary,
        'Framing unknown',
      );
      expect(
        CameraEffects.fromReply({'autoFraming': false}).summary,
        'Blur unknown',
      );
    });

    test('a non-map reply is unknown, not a crash', () {
      expect(CameraEffects.fromReply(null), CameraEffects.unknown);
      expect(CameraEffects.fromReply('blur'), CameraEffects.unknown);
      expect(
        CameraEffects.fromReply({'backgroundBlur': 'yes'}).backgroundBlur,
        isNull,
      );
    });
  });
}
