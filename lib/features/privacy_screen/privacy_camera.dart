// Dart side of the in-memory capture path.
//
// Design ported from SafeScreen by kv4u (MIT) — see THIRD_PARTY_NOTICES.md.
//
// Talks to windows/runner/dj_camera_channel.cpp over a method channel.
// Frames arrive as raw BGRA and are wrapped in a BMP container in Dart
// (see bmp_encoder.dart) because the face detector's only entry point
// decodes an encoded image.
//
// Nothing here touches the filesystem. That is the entire point: DJ has
// no disk-based camera path at all, so frames can never land in a
// synced folder.
//
// Availability is not assumed. `start` returns false on any failure —
// no Windows, no Media Foundation, a camera that will not produce RGB32
// — and the caller fails closed (the screen stays protected) rather than
// losing protection entirely.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'bmp_encoder.dart';
import 'camera_effects.dart';

/// One camera as the native side enumerated it.
class CameraDevice {
  const CameraDevice({required this.name, this.deviceId});

  /// Friendly name, e.g. "Integrated Webcam".
  final String name;

  /// Exact device path, for opening this specific camera. Null when the
  /// native side reported only a plain name.
  final String? deviceId;
}

class NativeCameraCapture {
  NativeCameraCapture({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'com.dhanunjay.dj/privacy_camera';

  final MethodChannel _channel;

  bool _running = false;
  String? _device;
  int _width = 0;
  int _height = 0;

  bool get isRunning => _running;

  /// Friendly name of the device the native side actually opened.
  String? get device => _device;

  int get width => _width;
  int get height => _height;

  /// Lists the video capture devices Media Foundation can see.
  /// Returns an empty list (never throws) when enumeration fails.
  Future<List<CameraDevice>> listDevices() async {
    if (!Platform.isWindows) return const [];
    try {
      final Map<dynamic, dynamic>? reply = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('listDevices');
      if (reply == null || reply['ok'] != true) return const [];
      final List<dynamic> raw =
          (reply['devices'] as List<dynamic>?) ?? const [];
      return raw
          .whereType<Map<dynamic, dynamic>>()
          .map((m) {
            final name = m['name']?.toString() ?? '';
            if (name.isEmpty) return null;
            return CameraDevice(
              name: name,
              deviceId: m['deviceId']?.toString(),
            );
          })
          .whereType<CameraDevice>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Opens the camera identified by [deviceId] (its exact device path),
  /// or by [preferredName] when no device path is known.
  ///
  /// If a camera was asked for and cannot be found, this fails rather
  /// than opening a different one: the caller then fails closed instead
  /// of silently watching through the wrong device.
  ///
  /// Returns false rather than throwing when in-memory capture is
  /// unavailable, so the caller can fail closed without special-casing
  /// errors.
  Future<bool> start({String? deviceId, String? preferredName}) async {
    if (!Platform.isWindows) return false;
    if (_running) return true;

    try {
      final Map<dynamic, dynamic>? reply = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('start', {
        if (deviceId != null) 'deviceId': deviceId,
        if (preferredName != null) 'deviceName': preferredName,
      });
      if (reply == null || reply['ok'] != true) return false;

      _device = reply['device'] as String?;
      _width = (reply['width'] as num?)?.toInt() ?? 0;
      _height = (reply['height'] as num?)?.toInt() ?? 0;
      if (_width <= 0 || _height <= 0) return false;

      _running = true;
      debugPrint(
        'DJ Privacy Screen: in-memory capture running on '
        '${_device ?? "camera"} at ${_width}x$_height',
      );
      return true;
    } catch (e) {
      debugPrint('DJ Privacy Screen: in-memory capture unavailable ($e)');
      return false;
    }
  }

  /// Grabs one frame, already wrapped as a BMP ready for the detector.
  ///
  /// Null means no usable frame. Callers must treat that as blindness —
  /// and therefore protect the screen — rather than as "nobody is there".
  Future<Uint8List?> grabFrame() async {
    if (!_running) return null;
    try {
      final Map<dynamic, dynamic>? reply = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('grab');
      if (reply == null || reply['ok'] != true) return null;

      final Uint8List? bgra = reply['bytes'] as Uint8List?;
      final int w = (reply['width'] as num?)?.toInt() ?? 0;
      final int h = (reply['height'] as num?)?.toInt() ?? 0;
      final int stride = (reply['stride'] as num?)?.toInt() ?? 0;
      if (bgra == null) return null;

      return encodeBgraAsBmp(bgra, width: w, height: h, stride: stride);
    } catch (e) {
      debugPrint('DJ Privacy Screen: in-memory grab failed ($e)');
      return null;
    }
  }

  /// Asks the camera whether it is blurring the background or
  /// auto-framing.
  ///
  /// Never throws; anything unexpected reads as [CameraEffects.unknown].
  Future<CameraEffects> queryEffects() async {
    if (!_running) return CameraEffects.unknown;
    try {
      return CameraEffects.fromReply(
        await _channel.invokeMethod<Map<dynamic, dynamic>>('effects'),
      );
    } catch (e) {
      debugPrint('DJ Privacy Screen: camera effects query failed ($e)');
      return CameraEffects.unknown;
    }
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _device = null;
    _width = 0;
    _height = 0;
    try {
      await _channel.invokeMethod<Map<dynamic, dynamic>>('stop');
    } catch (e) {
      debugPrint('DJ Privacy Screen: in-memory capture stop failed ($e)');
    }
  }
}
