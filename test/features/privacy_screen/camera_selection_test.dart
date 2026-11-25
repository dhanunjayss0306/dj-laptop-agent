// Tests for lib/features/privacy_screen/camera_selection.dart.
// Design ported from SafeScreen by kv4u (MIT).
//
// Virtual camera software applies background blur or replacement before
// any frame reaches the detector, which erases the person standing
// behind the user. So DJ prefers real hardware, and flags a virtual
// camera rather than pretending it protects.

import 'package:dj/features/privacy_screen/camera_selection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseCameraName', () {
    test('splits a friendly name from its device path', () {
      final CameraName parsed = parseCameraName(
        r'Integrated Webcam <\\?\usb#vid_0c45&pid_6a10&mi_00#6&1f2a3b4c&0&0000#{e5323777-f976-4f5b-9b55-b94699c46e44}\global>',
      );
      expect(parsed.display, 'Integrated Webcam');
      expect(parsed.deviceId, isNotNull);
      expect(parsed.deviceId, startsWith(r'\\?\usb'));
    });

    test('a plain name has no device id', () {
      final CameraName parsed = parseCameraName('Integrated Webcam');
      expect(parsed.display, 'Integrated Webcam');
      expect(parsed.deviceId, isNull);
    });

    test('a name ending in angle brackets without a display keeps the raw name',
        () {
      final CameraName parsed = parseCameraName('<weird>');
      expect(parsed.display, '<weird>');
    });
  });

  group('looksLikeVirtualCamera', () {
    test('flags known virtual camera software', () {
      expect(looksLikeVirtualCamera('OBS Virtual Camera'), isTrue);
      expect(looksLikeVirtualCamera('NVIDIA Broadcast'), isTrue);
      expect(looksLikeVirtualCamera('XSplit VCam'), isTrue);
      expect(looksLikeVirtualCamera('ManyCam Virtual Webcam'), isTrue);
      expect(looksLikeVirtualCamera('Snap Camera'), isTrue);
    });

    test('does not flag real hardware', () {
      expect(looksLikeVirtualCamera('Integrated Webcam'), isFalse);
      expect(looksLikeVirtualCamera('USB2.0 HD UVC WebCam'), isFalse);
      expect(looksLikeVirtualCamera('FaceTime HD Camera'), isFalse);
    });
  });

  group('chooseCamera', () {
    test('prefers a physical front camera over a virtual front camera', () {
      final CameraChoice? choice = chooseCamera(const [
        CameraOption(name: 'OBS Virtual Camera', isFront: true),
        CameraOption(name: 'Integrated Webcam', isFront: true),
      ]);
      expect(choice, isNotNull);
      expect(choice!.option.name, 'Integrated Webcam');
      expect(choice.isVirtual, isFalse);
    });

    test('prefers any physical camera over a virtual front camera', () {
      final CameraChoice? choice = chooseCamera(const [
        CameraOption(name: 'OBS Virtual Camera', isFront: true),
        CameraOption(name: 'USB2.0 HD UVC WebCam', isFront: false),
      ]);
      expect(choice, isNotNull);
      expect(choice!.option.name, 'USB2.0 HD UVC WebCam');
      expect(choice.isVirtual, isFalse);
    });

    test('uses a virtual camera when it is the only one, and flags it', () {
      final CameraChoice? choice = chooseCamera(const [
        CameraOption(name: 'OBS Virtual Camera', isFront: true),
      ]);
      expect(choice, isNotNull);
      expect(choice!.isVirtual, isTrue);
    });

    test('empty list gives null', () {
      expect(chooseCamera(const []), isNull);
    });

    test('the first physical camera wins when several are present', () {
      final CameraChoice? choice = chooseCamera(const [
        CameraOption(name: 'USB2.0 HD UVC WebCam', isFront: false),
        CameraOption(name: 'Integrated Webcam', isFront: true),
      ]);
      // Physical front beats physical rear.
      expect(choice!.option.name, 'Integrated Webcam');
    });
  });
}
