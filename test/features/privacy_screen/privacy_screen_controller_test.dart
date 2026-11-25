// Tests for lib/features/privacy_screen/privacy_screen_controller.dart
// and the Privacy Screen hotkey in lib/platform/hotkey_channel.dart.
//
// The override (Ctrl+Alt+P) is the behaviour the user asked for by
// name, so it is tested directly: it only works while protection is
// running, one press reveals immediately, the next resumes normal
// face-detection rules, and the paused state is always visible in the
// status message. The laptop-only guard is tested too — this VM is
// Linux, so the real platform check fires here.

import 'package:dj/features/privacy_screen/gaze_detector.dart';
import 'package:dj/features/privacy_screen/privacy_screen_controller.dart';
import 'package:dj/features/privacy_screen/privacy_screen_service.dart';
import 'package:dj/features/privacy_screen/privacy_window_ops.dart';
import 'package:dj/platform/hotkey_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeWindowOps implements PrivacyWindowOps {
  bool blackedOut = false;
  int showBlackoutCalls = 0;
  int restorePanelCalls = 0;

  @override
  bool get isBlackedOut => blackedOut;

  @override
  Future<void> preparePanel() async {}

  @override
  Future<void> showBlackout() async {
    blackedOut = true;
    showBlackoutCalls++;
  }

  @override
  Future<void> restorePanel() async {
    blackedOut = false;
    restorePanelCalls++;
  }

  @override
  Future<bool> isVisible() async => true;

  @override
  Future<void> showAndFocus() async {}

  @override
  Future<void> hide() async {}
}

class _FakeService extends PrivacyScreenService {
  _FakeService({required super.gazeDetector});

  bool started = false;

  @override
  Future<void> start() async {
    started = true;
  }

  @override
  Future<void> stop() async {
    started = false;
  }

  /// Mimics the real service calling its gaze callback when visibility flips.
  void simulateGazeChange() => onGazeStateChanged?.call();
}

const GazeSample _good = GazeSample(
  faceCount: 1,
  yawDeg: 0,
  pitchDeviation: 0.0,
  rollDeg: 0,
);

/// Lets the controller's unawaited window-mode application finish.
Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  group('PrivacyScreenController — laptop-only guard', () {
    test('startProtection on a non-Windows machine reports laptop-only',
        () async {
      final PrivacyScreenController controller = PrivacyScreenController(
        settings: const PrivacyScreenSettings(),
        // No isWindows override: this VM is Linux, so the real check fires.
      );
      await controller.startProtection();
      expect(controller.isRunning, isFalse);
      expect(controller.error, contains('laptop-only'));
      controller.dispose();
    });

    test('the service itself refuses to start off Windows', () async {
      String? error;
      final PrivacyScreenService service = PrivacyScreenService(
        gazeDetector: GazeDetectorService(),
        onError: (message) => error = message,
      );
      await service.start();
      expect(error, contains('laptop-only'));
      expect(service.isRunning, isFalse);
    });
  });

  group('PrivacyScreenController — override (Ctrl+Alt+P)', () {
    late GazeDetectorService gaze;
    late _FakeService service;
    late _FakeWindowOps ops;
    late PrivacyScreenController controller;
    PrivacyScreenSettings? savedSettings;

    setUp(() {
      gaze = GazeDetectorService(
        sensitivity: 0.75,
        detectShoulderSurfers: true,
      );
      service = _FakeService(gazeDetector: gaze);
      ops = _FakeWindowOps();
      savedSettings = null;
      controller = PrivacyScreenController(
        settings: const PrivacyScreenSettings(sensitivity: 0.75),
        gazeDetector: gaze,
        service: service,
        windowOps: ops,
        isWindows: true,
        onSettingsChanged: (settings) => savedSettings = settings,
      );
    });

    tearDown(() {
      controller.dispose();
    });

    test('protection starts blacked out until the camera confirms looking',
        () async {
      await controller.startProtection();
      expect(controller.isRunning, isTrue);
      expect(ops.blackedOut, isTrue);
      expect(controller.isProtected, isTrue);
      expect(controller.statusMessage, contains('Protected'));
    });

    test('good frames reveal the screen; a look-away hides it again',
        () async {
      await controller.startProtection();
      expect(ops.blackedOut, isTrue);
      // Default sensitivity 0.75 needs 4 consecutive good frames.
      for (int i = 0; i < 4; i++) {
        gaze.observe(_good);
      }
      service.simulateGazeChange();
      await _flush();
      expect(ops.blackedOut, isFalse);
      expect(controller.statusMessage, 'Looking at screen');

      gaze.observe(const GazeSample.noFace());
      service.simulateGazeChange();
      await _flush();
      expect(ops.blackedOut, isTrue);
    });

    test('one override press reveals immediately, even with no face',
        () async {
      await controller.startProtection();
      expect(ops.blackedOut, isTrue);
      expect(controller.toggleOverride(), isTrue);
      await _flush();
      expect(controller.isOverrideOn, isTrue);
      expect(ops.blackedOut, isFalse);
      expect(
        controller.statusMessage,
        'Privacy paused — press Ctrl+Alt+P to resume',
      );
    });

    test('a second press resumes normal face-detection rules', () async {
      await controller.startProtection();
      controller.toggleOverride();
      await _flush();
      expect(ops.blackedOut, isFalse);
      // No face in view, so resuming protection blacks out again.
      controller.toggleOverride();
      await _flush();
      expect(controller.isOverrideOn, isFalse);
      expect(ops.blackedOut, isTrue);
      expect(controller.isProtected, isTrue);
    });

    test('the override does nothing while protection is off', () async {
      expect(controller.toggleOverride(), isFalse);
      expect(controller.isOverrideOn, isFalse);
      expect(ops.showBlackoutCalls, 0);
      expect(ops.restorePanelCalls, 0);
    });

    test('stopping protection clears the override and restores the panel',
        () async {
      await controller.startProtection();
      controller.toggleOverride();
      await _flush();
      expect(controller.isOverrideOn, isTrue);
      await controller.stopProtection();
      expect(controller.isRunning, isFalse);
      expect(controller.isOverrideOn, isFalse);
      expect(ops.blackedOut, isFalse);
      expect(controller.statusMessage, 'Protection off');
    });

    test('settings changes are reported for persistence', () {
      controller.setSensitivity(0.9);
      expect(savedSettings?.sensitivity, 0.9);
      controller.setDetectShoulderSurfers(false);
      expect(savedSettings?.detectShoulderSurfers, isFalse);
      controller.setStartOnLaunch(true);
      expect(savedSettings?.startOnLaunch, isTrue);
    });
  });

  group('HotkeyChannel — privacy hotkey', () {
    const MethodChannel channel = MethodChannel('com.dhanunjay.dj/hotkey');

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('registerPrivacyHotkey sends Ctrl+Alt+P (vk 0x50)', () async {
      MethodCall? lastCall;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        lastCall = call;
        return <String, dynamic>{'ok': true};
      });
      final HotkeyChannel hotkey = HotkeyChannel();
      expect(await hotkey.registerPrivacyHotkey(), isTrue);
      expect(lastCall?.method, 'registerPrivacyHotkey');
      expect(lastCall?.arguments['modifiers'], <String>['ctrl', 'alt']);
      expect(lastCall?.arguments['vk'], 0x50);
      await hotkey.dispose();
    });

    test('registerPrivacyHotkey returns false when the native side refuses',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        return <String, dynamic>{
          'ok': false,
          'message': 'hotkey already in use — pick another',
        };
      });
      final HotkeyChannel hotkey = HotkeyChannel();
      expect(await hotkey.registerPrivacyHotkey(), isFalse);
      await hotkey.dispose();
    });

    test('a native onPrivacyHotkeyPressed call fires the stream', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        return <String, dynamic>{'ok': true};
      });
      final HotkeyChannel hotkey = HotkeyChannel();
      bool fired = false;
      hotkey.onPrivacyHotkeyPressed.listen((_) => fired = true);
      await TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .handlePlatformMessage(
        'com.dhanunjay.dj/hotkey',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onPrivacyHotkeyPressed', <String, dynamic>{}),
        ),
        (ByteData? data) {},
      );
      expect(fired, isTrue);
      await hotkey.dispose();
    });

    test('the privacy hotkey id does not disturb the main hotkey', () async {
      final List<String> methods = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        methods.add(call.method);
        return <String, dynamic>{'ok': true};
      });
      final HotkeyChannel hotkey = HotkeyChannel();
      await hotkey.registerHotkey();
      await hotkey.registerPrivacyHotkey();
      expect(methods, ['registerHotkey', 'registerPrivacyHotkey']);
      await hotkey.dispose();
    });
  });
}
