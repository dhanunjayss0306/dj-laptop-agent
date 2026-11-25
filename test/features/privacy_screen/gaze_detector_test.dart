// Tests for lib/features/privacy_screen/gaze_detector.dart.
// Design ported from SafeScreen by kv4u (MIT).
//
// The detector is the fail-closed core of Privacy Screen: it starts
// protected, hides fast, reveals slow, and treats missing or stale
// evidence as "protect". These tests pin each of those behaviours.

import 'package:dj/features/privacy_screen/gaze_detector.dart';
import 'package:flutter_test/flutter_test.dart';

const GazeSample _good = GazeSample(
  faceCount: 1,
  yawDeg: 0,
  pitchDeviation: 0.0,
  rollDeg: 0,
);

void main() {
  group('GazeDetectorService', () {
    test('starts protected, initialising — never visible before proof', () {
      final GazeDetectorService d = GazeDetectorService();
      expect(d.isScreenVisible, isFalse);
      expect(d.isProtected, isTrue);
      expect(d.reason, ProtectionReason.initialising);
    });

    test('reveals only after several consecutive good frames', () {
      final GazeDetectorService d =
          GazeDetectorService(sensitivity: 0.5); // framesToReveal = 3
      expect(d.framesToReveal, 3);
      d.observe(_good);
      d.observe(_good);
      expect(d.isScreenVisible, isFalse);
      d.observe(_good);
      expect(d.isScreenVisible, isTrue);
      expect(d.reason, ProtectionReason.none);
    });

    test('one bad frame hides the screen again (hide fast)', () {
      final GazeDetectorService d = GazeDetectorService(sensitivity: 0.5);
      for (int i = 0; i < 3; i++) {
        d.observe(_good);
      }
      expect(d.isScreenVisible, isTrue);
      d.observe(const GazeSample.noFace());
      expect(d.isScreenVisible, isFalse);
      expect(d.reason, ProtectionReason.noFace);
    });

    test('a bad frame resets the reveal count', () {
      final GazeDetectorService d = GazeDetectorService(sensitivity: 0.5);
      d.observe(_good);
      d.observe(_good);
      d.observe(const GazeSample.noFace());
      d.observe(_good);
      expect(d.isScreenVisible, isFalse);
      expect(d.confidence, closeTo(1 / 3, 0.01));
    });

    test('a second face protects when shoulder-surfer detection is on', () {
      final GazeDetectorService d = GazeDetectorService();
      for (int i = 0; i < 3; i++) {
        d.observe(_good);
      }
      expect(d.isScreenVisible, isTrue);
      d.observe(const GazeSample(faceCount: 2));
      expect(d.isScreenVisible, isFalse);
      expect(d.reason, ProtectionReason.multipleFaces);
    });

    test('a second face is fine when shoulder-surfer detection is off', () {
      final GazeDetectorService d =
          GazeDetectorService(detectShoulderSurfers: false);
      for (int i = 0; i < 4; i++) {
        d.observe(const GazeSample(faceCount: 2));
      }
      expect(d.isScreenVisible, isTrue);
    });

    test('turning away protects with the lookedAway reason', () {
      final GazeDetectorService d = GazeDetectorService(sensitivity: 0.5);
      for (int i = 0; i < 3; i++) {
        d.observe(_good);
      }
      d.observe(const GazeSample(faceCount: 1, yawDeg: 40));
      expect(d.isScreenVisible, isFalse);
      expect(d.reason, ProtectionReason.lookedAway);
    });

    test('a nod (pitch deviation) protects', () {
      final GazeDetectorService d = GazeDetectorService(sensitivity: 0.5);
      for (int i = 0; i < 3; i++) {
        d.observe(_good);
      }
      d.observe(
        const GazeSample(faceCount: 1, yawDeg: 0, pitchDeviation: 0.5),
      );
      expect(d.reason, ProtectionReason.lookedAway);
    });

    test('closed eyes protect only when the platform measures them', () {
      final GazeDetectorService d = GazeDetectorService(sensitivity: 0.5);
      for (int i = 0; i < 3; i++) {
        d.observe(_good);
      }
      d.observe(const GazeSample(
        faceCount: 1,
        yawDeg: 0,
        leftEyeOpen: 0.1,
        rightEyeOpen: 0.1,
      ));
      expect(d.reason, ProtectionReason.eyesClosed);
    });

    test('a detector error protects with the detectorError reason', () {
      final GazeDetectorService d = GazeDetectorService();
      d.observeError();
      expect(d.isScreenVisible, isFalse);
      expect(d.reason, ProtectionReason.detectorError);
    });

    test('stale samples re-protect the screen', () {
      DateTime now = DateTime(2026, 11, 25, 12, 0, 0);
      final GazeDetectorService d = GazeDetectorService();
      d.clock = () => now;
      for (int i = 0; i < 4; i++) {
        d.observe(_good);
      }
      expect(d.isScreenVisible, isTrue);
      now = now.add(const Duration(seconds: 4));
      expect(d.isScreenVisible, isFalse);
      expect(d.reason, ProtectionReason.stale);
    });

    test('sensitivity maps to thresholds and frame counts', () {
      final GazeDetectorService strict =
          GazeDetectorService(sensitivity: 1.0);
      expect(strict.maxYawDeg, closeTo(15, 0.01));
      expect(strict.framesToReveal, 4);
      expect(strict.framesToProtect, 1);

      final GazeDetectorService lenient =
          GazeDetectorService(sensitivity: 0.0);
      expect(lenient.maxYawDeg, closeTo(40, 0.01));
      expect(lenient.framesToReveal, 2);
      expect(lenient.framesToProtect, 2);
    });

    test('lenient settings need two bad frames to hide', () {
      final GazeDetectorService d = GazeDetectorService(sensitivity: 0.0);
      d.observe(_good);
      d.observe(_good);
      expect(d.isScreenVisible, isTrue);
      d.observe(const GazeSample.noFace());
      expect(d.isScreenVisible, isTrue);
      d.observe(const GazeSample.noFace());
      expect(d.isScreenVisible, isFalse);
    });

    test('reset returns to the initial protected state', () {
      final GazeDetectorService d = GazeDetectorService();
      for (int i = 0; i < 4; i++) {
        d.observe(_good);
      }
      expect(d.isScreenVisible, isTrue);
      d.reset();
      expect(d.isScreenVisible, isFalse);
      expect(d.reason, ProtectionReason.initialising);
    });

    test('reason messages are plain words', () {
      expect(ProtectionReason.noFace.message, 'No one detected');
      expect(ProtectionReason.multipleFaces.message,
          'Someone else is looking');
      expect(ProtectionReason.lookedAway.message, 'Looking away');
      expect(ProtectionReason.none.message, 'Looking at screen');
    });
  });
}
