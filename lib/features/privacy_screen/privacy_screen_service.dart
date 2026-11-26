// Camera + face detection pipeline for Privacy Screen.
//
// Design ported from SafeScreen by kv4u (MIT) — see THIRD_PARTY_NOTICES.md.
//
// Windows only. Frames come from DJ's own Media Foundation path
// (`privacy_camera.dart`, `windows/runner/dj_camera_channel.cpp`) and
// never touch the disk. There is NO disk-based fallback in DJ: if the
// in-memory camera cannot start, protection fails closed with a plain
// error instead of writing photographs of the user to disk.
//
// Detection runs in `FaceDetectionMode.fast`, which yields the bounding
// box plus six keypoints; those keypoints are converted to real head
// pose by `head_pose.dart`. The BlazeFace model
// (`face_detection_front.tflite`, Google MediaPipe, Apache 2.0) ships
// inside the `face_detection_tflite` package — DJ downloads no model.

import 'dart:async';
import 'dart:io';

import 'package:face_detection_tflite/face_detection_tflite.dart' as tflite;
import 'package:flutter/foundation.dart';

import 'camera_effects.dart';
import 'camera_selection.dart';
import 'gaze_detector.dart';
import 'head_pose.dart';
import 'privacy_camera.dart';

class PrivacyScreenService {
  PrivacyScreenService({
    required this.gazeDetector,
    this.onGazeStateChanged,
    this.onError,
    NativeCameraCapture? nativeCamera,
  }) : _nativeCamera = nativeCamera ?? NativeCameraCapture();

  final GazeDetectorService gazeDetector;

  /// Fired only when the protected/visible state actually flips.
  /// Mutable so the controller can wire it even when a service is
  /// injected (tests).
  VoidCallback? onGazeStateChanged;

  /// Called on unrecoverable camera or detector errors with a readable
  /// message. Mutable, like [onGazeStateChanged].
  void Function(String message)? onError;

  tflite.FaceDetector? _tfliteDetector;
  final NativeCameraCapture _nativeCamera;
  final PitchBaseline _pitchBaseline = PitchBaseline();
  Timer? _nextCapture;
  bool _stopping = false;
  bool _isProcessing = false;

  /// Sampling cadence. Faster while the screen is exposed, because that
  /// is when a missed look-away actually costs something; slower while
  /// already protected.
  static const Duration _intervalWhileVisible =
      Duration(milliseconds: 200);
  static const Duration _intervalWhileProtected =
      Duration(milliseconds: 400);

  static const Duration _effectsCheckInterval = Duration(seconds: 5);

  String? _cameraName;
  String? _cameraDeviceId;
  bool _isVirtualCamera = false;

  /// Name of the camera actually in use.
  String? get cameraName => _cameraName;

  /// True when the active camera is virtual-camera software rather than
  /// hardware. Background blur or replacement in such software removes
  /// anyone standing behind the user, so shoulder-surfer detection
  /// cannot be relied on. The UI must say so rather than reporting
  /// protection it cannot give.
  bool get isVirtualCamera => _isVirtualCamera;

  HeadPose? _lastPose;

  /// The most recent usable head-pose reading, for the status readout.
  /// Null when no face is in frame or the keypoints were unusable.
  HeadPose? get lastPose => _lastPose;

  /// True when frames come from the in-memory Media Foundation path
  /// and never touch the disk. DJ has no other path.
  bool get isInMemoryCapture => _nativeCamera.isRunning;

  CameraEffects _effects = CameraEffects.unknown;
  DateTime? _effectsCheckedAt;

  /// Effects the camera reports applying before frames reach the
  /// detector. A warning and nothing more: the detector keeps running,
  /// and the UI says plainly that shoulder-surfer detection is limited
  /// rather than reporting protection it cannot give.
  CameraEffects get effects => _effects;

  Uint8List? _lastFrame;

  /// Whether to hold on to the latest frame so the status page can draw
  /// it. Off by default so frames never outlive detection when the user
  /// is not viewing Privacy Screen.
  bool keepPreviewFrame = false;

  /// The most recent frame, as an encoded image. Only populated on the
  /// in-memory path.
  Uint8List? get lastFrameBytes => _lastFrame;

  /// Frame dimensions on the in-memory path; zero otherwise.
  int get frameWidth => _nativeCamera.width;
  int get frameHeight => _nativeCamera.height;

  bool get isRunning => _nativeCamera.isRunning && _nextCapture != null;

  /// Diagnostics for the UI.
  bool get isPitchCalibrated => _pitchBaseline.isCalibrated;

  /// Starts the camera and the detection loop.
  ///
  /// Windows only. On any other platform this reports the laptop-only
  /// message and returns without touching a camera.
  Future<void> start() async {
    if (!Platform.isWindows) {
      onError?.call(
        'Privacy Screen is laptop-only. It needs a Windows laptop '
        'with a webcam.',
      );
      return;
    }
    if (_nativeCamera.isRunning) return;
    _stopping = false;

    try {
      final tflite.FaceDetector detector = tflite.FaceDetector();
      await detector.initialize(model: tflite.FaceDetectionModel.frontCamera);
      _tfliteDetector = detector;
    } catch (e) {
      debugPrint('DJ Privacy Screen: TFLite init failed: $e');
      onError?.call('Face detection failed to initialise: $e');
      return;
    }

    final List<CameraDevice> devices = await _nativeCamera.listDevices();
    if (devices.isEmpty) {
      _disposeDetector();
      onError?.call('No camera found on this device.');
      return;
    }
    // Prefer real hardware. Virtual camera software applies background
    // blur or replacement before any frame reaches us, which erases the
    // very person shoulder-surfer detection exists to catch — silently.
    final CameraChoice? choice = chooseCamera(
      devices
          .map(
            (CameraDevice d) => CameraOption.fromRaw(
              d.deviceId == null ? d.name : '${d.name} <${d.deviceId}>',
              isFront: true,
            ),
          )
          .toList(),
    );
    if (choice == null) {
      _disposeDetector();
      onError?.call('No camera found on this device.');
      return;
    }
    _cameraName = choice.option.name;
    _cameraDeviceId = choice.option.deviceId;
    _isVirtualCamera = choice.isVirtual;
    if (choice.isVirtual) {
      debugPrint(
        'DJ Privacy Screen: only a virtual camera is available '
        '(${choice.option.name}); background effects may defeat '
        'shoulder-surfer detection',
      );
    }

    // In-memory capture is the only path. If it cannot start, fail
    // closed with a plain error rather than writing frames to disk.
    if (!await _nativeCamera.start(
      deviceId: _cameraDeviceId,
      preferredName: _cameraName,
    )) {
      _disposeDetector();
      onError?.call(
        'Could not open the camera.\n\n'
        'This usually means another app is already using it — close '
        'Teams, Zoom, or your browser and try again. Check Windows '
        'camera privacy settings too.',
      );
      return;
    }

    _scheduleNextCapture(Duration.zero);
  }

  void _disposeDetector() {
    try {
      _tfliteDetector?.dispose();
    } catch (_) {}
    _tfliteDetector = null;
  }

  /// Self-scheduling instead of `Timer.periodic`: the next capture is
  /// only queued once the previous one has finished, so a slow frame
  /// can never let work pile up behind it.
  void _scheduleNextCapture(Duration delay) {
    if (_stopping) return;
    _nextCapture?.cancel();
    _nextCapture = Timer(delay, _captureAndDetect);
  }

  Future<void> _captureAndDetect() async {
    if (_stopping) return;
    if (_tfliteDetector == null) return;
    if (!_nativeCamera.isRunning) return;
    if (_isProcessing) {
      _scheduleNextCapture(_currentInterval);
      return;
    }

    _isProcessing = true;
    final bool wasVisible = gazeDetector.isScreenVisible;
    try {
      final DateTime now = DateTime.now();
      if (_effectsCheckedAt == null ||
          now.difference(_effectsCheckedAt!) >= _effectsCheckInterval) {
        _effectsCheckedAt = now;
        _effects = await _nativeCamera.queryEffects();
      }
      final Uint8List? bytes = await _nativeCamera.grabFrame();
      _lastFrame = keepPreviewFrame ? bytes : null;
      if (bytes == null) {
        gazeDetector.observeError();
      } else {
        // `fast` mode is deliberate. The package defaults to
        // FaceDetectionMode.full, which additionally runs a 468-point
        // mesh and two iris models per face — none of which this
        // feature uses.
        final List<tflite.Face> faces = await _tfliteDetector!.detectFaces(
          bytes,
          mode: tflite.FaceDetectionMode.fast,
        );
        _observeFaces(faces);
      }
    } catch (e) {
      debugPrint('DJ Privacy Screen capture: $e');
      gazeDetector.observeError();
    } finally {
      _isProcessing = false;
      if (gazeDetector.isScreenVisible != wasVisible) {
        onGazeStateChanged?.call();
      }
      _scheduleNextCapture(_currentInterval);
    }
  }

  Duration get _currentInterval => gazeDetector.isScreenVisible
      ? _intervalWhileVisible
      : _intervalWhileProtected;

  void _observeFaces(List<tflite.Face> faces) {
    if (faces.isEmpty) {
      _lastPose = null;
      gazeDetector.observe(const GazeSample.noFace());
      return;
    }

    // More than one face is itself disqualifying, so pose does not matter.
    if (faces.length > 1) {
      gazeDetector.observe(GazeSample(faceCount: faces.length));
      return;
    }

    final FaceKeypoints? keypoints = _keypointsOf(faces.first);
    if (keypoints == null) {
      // A face without usable keypoints tells us nothing about where it
      // is looking. Treat that as blindness, not as attentiveness.
      gazeDetector.observeError();
      return;
    }

    final HeadPose? pose = estimateHeadPose(keypoints);
    if (pose == null) {
      _lastPose = null;
      gazeDetector.observeError();
      return;
    }
    _lastPose = pose;

    final double deviation = _pitchBaseline.deviation(pose.pitchRatio);
    gazeDetector.observe(
      GazeSample(
        faceCount: 1,
        yawDeg: pose.yaw,
        pitchDeviation: deviation,
        rollDeg: pose.roll,
      ),
    );

    // Only learn the neutral pose from frames where the user is squarely
    // facing the screen, otherwise the baseline drifts toward whatever
    // angle they happen to hold while looking away.
    if (pose.yaw.abs() < 10.0 && pose.roll.abs() < 15.0) {
      _pitchBaseline.observe(pose.pitchRatio);
    }
  }

  /// Extracts the five keypoints the pose estimator needs, or null if
  /// the detector did not supply all of them.
  FaceKeypoints? _keypointsOf(tflite.Face face) {
    final tflite.FaceLandmarks marks = face.landmarks;
    final tflite.Point? leftEye = marks.leftEye;
    final tflite.Point? rightEye = marks.rightEye;
    final tflite.Point? nose = marks.noseTip;
    final tflite.Point? leftTragion = marks.leftEyeTragion;
    final tflite.Point? rightTragion = marks.rightEyeTragion;

    if (leftEye == null ||
        rightEye == null ||
        nose == null ||
        leftTragion == null ||
        rightTragion == null) {
      return null;
    }
    return FaceKeypoints(
      leftEye: Pt(leftEye.x, leftEye.y),
      rightEye: Pt(rightEye.x, rightEye.y),
      noseTip: Pt(nose.x, nose.y),
      leftTragion: Pt(leftTragion.x, leftTragion.y),
      rightTragion: Pt(rightTragion.x, rightTragion.y),
    );
  }

  Future<void> stop() async {
    _stopping = true;
    _nextCapture?.cancel();
    _nextCapture = null;

    try {
      await _nativeCamera.stop();
    } catch (_) {}

    try {
      _tfliteDetector?.dispose();
    } catch (_) {}
    _tfliteDetector = null;

    _isProcessing = false;
    _lastPose = null;
    _cameraName = null;
    _cameraDeviceId = null;
    _isVirtualCamera = false;
    _lastFrame = null;
    _effects = CameraEffects.unknown;
    _effectsCheckedAt = null;
  }
}
