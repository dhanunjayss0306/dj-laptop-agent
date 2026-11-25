// Tests for lib/features/privacy_screen/head_pose.dart.
// Design ported from SafeScreen by kv4u (MIT).
//
// The estimator reads yaw, roll and a pitch ratio from five BlazeFace
// keypoints. These tests pin the geometry: a face looking straight
// ahead reads ~0 yaw and ~0 roll; moving the nose sideways turns the
// yaw; tilting the eye line tilts the roll; degenerate keypoints give
// null rather than a made-up pose.

import 'package:dj/features/privacy_screen/head_pose.dart';
import 'package:flutter_test/flutter_test.dart';

const FaceKeypoints _forward = FaceKeypoints(
  leftEye: Pt(100, 100),
  rightEye: Pt(200, 100),
  noseTip: Pt(150, 130),
  leftTragion: Pt(80, 110),
  rightTragion: Pt(220, 110),
);

void main() {
  group('estimateHeadPose', () {
    test('a face looking straight ahead reads ~0 yaw and ~0 roll', () {
      final HeadPose? pose = estimateHeadPose(_forward);
      expect(pose, isNotNull);
      expect(pose!.yaw, closeTo(0, 0.5));
      expect(pose.roll, closeTo(0, 0.5));
      // Nose 30 below the eye line, eyes 100 apart, measured
      // perpendicular to the eye line.
      expect(pose.pitchRatio, closeTo(0.3, 0.01));
    });

    test('nose left of the eye midpoint is a left turn (negative yaw)', () {
      final HeadPose? pose = estimateHeadPose(
        _forward.copyWith(noseTip: const Pt(120, 130)),
      );
      expect(pose, isNotNull);
      expect(pose!.yaw, lessThan(-5));
    });

    test('nose right of the eye midpoint is a right turn (positive yaw)', () {
      final HeadPose? pose = estimateHeadPose(
        _forward.copyWith(noseTip: const Pt(180, 130)),
      );
      expect(pose, isNotNull);
      expect(pose!.yaw, greaterThan(5));
    });

    test('a tilted eye line reads as roll', () {
      final HeadPose? pose = estimateHeadPose(
        _forward.copyWith(rightEye: const Pt(200, 120)),
      );
      expect(pose, isNotNull);
      expect(pose!.roll, greaterThan(5));
    });

    test('a lower nose reads as a larger pitch ratio', () {
      final HeadPose? low = estimateHeadPose(
        _forward.copyWith(noseTip: const Pt(150, 150)),
      );
      final HeadPose? high = estimateHeadPose(
        _forward.copyWith(noseTip: const Pt(150, 115)),
      );
      expect(low, isNotNull);
      expect(high, isNotNull);
      expect(low!.pitchRatio, greaterThan(high!.pitchRatio));
    });

    test('degenerate keypoints give null, never a made-up pose', () {
      // Eyes on top of each other: no eye distance to measure against.
      expect(
        estimateHeadPose(
          _forward.copyWith(rightEye: const Pt(100, 100)),
        ),
        isNull,
      );
      // Ears on top of each other.
      expect(
        estimateHeadPose(
          _forward.copyWith(rightTragion: const Pt(80, 110)),
        ),
        isNull,
      );
      // Zero-width face.
      expect(
        estimateHeadPose(
          const FaceKeypoints(
            leftEye: Pt(150, 100),
            rightEye: Pt(150, 100),
            noseTip: Pt(150, 130),
            leftTragion: Pt(150, 110),
            rightTragion: Pt(150, 110),
          ),
        ),
        isNull,
      );
    });

    test('yaw is bounded to +/-90 degrees', () {
      final HeadPose? pose = estimateHeadPose(
        _forward.copyWith(noseTip: const Pt(900, 130)),
      );
      expect(pose, isNotNull);
      expect(pose!.yaw.abs(), lessThanOrEqualTo(90));
    });
  });

  group('PitchBaseline', () {
    test('unlearned baseline falls back to the nominal value', () {
      final PitchBaseline baseline = PitchBaseline();
      expect(baseline.isCalibrated, isFalse);
      expect(baseline.value, 0.62);
      // Signed deviation from the nominal: 0.9 - 0.62.
      expect(baseline.deviation(0.9), closeTo(0.28, 0.01));
    });

    test('after learning, the neutral pose reads ~0 and a nod reads large',
        () {
      final PitchBaseline baseline = PitchBaseline();
      for (int i = 0; i < 60; i++) {
        baseline.observe(0.2);
      }
      expect(baseline.isCalibrated, isTrue);
      expect(baseline.deviation(0.2), lessThan(0.05));
      expect(baseline.deviation(0.5), greaterThan(0.2));
    });

    test('an outlier does not drag the baseline', () {
      final PitchBaseline baseline = PitchBaseline();
      for (int i = 0; i < 60; i++) {
        baseline.observe(0.2);
      }
      baseline.observe(0.9);
      expect(baseline.deviation(0.2), lessThan(0.05));
    });

    test('reset forgets everything and returns to the nominal', () {
      final PitchBaseline baseline = PitchBaseline();
      for (int i = 0; i < 60; i++) {
        baseline.observe(0.2);
      }
      baseline.reset();
      expect(baseline.isCalibrated, isFalse);
      expect(baseline.value, 0.62);
      expect(baseline.deviation(0.9), closeTo(0.28, 0.01));
    });
  });
}
