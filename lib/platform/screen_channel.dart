// Screen capture channel (Windows).
//
// Native side: windows/runner/dj_screen_channel.cpp, channel
// 'com.dhanunjay.dj/screen'. Captures the full virtual desktop (all
// monitors) to PNG bytes with Win32 BitBlt + GDI+ and returns the monitor
// bounds. v1 is full-screen only; there is no region cropping.
//
// The PNG bytes are sent to the model by the Dart caller; this class only
// captures and returns them.

import 'package:flutter/services.dart';

/// One monitor reported by [ScreenChannel.captureScreen].
class DjMonitor {
  const DjMonitor({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.isPrimary,
  });

  factory DjMonitor.fromMap(Map<String, dynamic> map) {
    return DjMonitor(
      x: (map['x'] as num?)?.toInt() ?? 0,
      y: (map['y'] as num?)?.toInt() ?? 0,
      width: (map['width'] as num?)?.toInt() ?? 0,
      height: (map['height'] as num?)?.toInt() ?? 0,
      isPrimary: map['isPrimary'] as bool? ?? false,
    );
  }

  final int x;
  final int y;
  final int width;
  final int height;
  final bool isPrimary;
}

/// Result of [ScreenChannel.captureScreen].
class ScreenCapture {
  const ScreenCapture({
    required this.png,
    required this.width,
    required this.height,
    required this.monitors,
  });

  final Uint8List png;
  final int width;
  final int height;
  final List<DjMonitor> monitors;
}

class ScreenChannel {
  ScreenChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'com.dhanunjay.dj/screen';

  final MethodChannel _channel;

  /// Captures the primary monitor (in practice the whole virtual desktop,
  /// all monitors) to PNG bytes.
  ///
  /// Returns null when capture fails; the failure reason is only visible
  /// in the native log, so callers must treat null as "try again later".
  /// Throws nothing.
  Future<ScreenCapture?> captureScreen() async {
    try {
      final Map<dynamic, dynamic>? result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('captureScreen');
      if (result == null || result['ok'] != true) {
        return null;
      }
      final Uint8List? png = result['png'] as Uint8List?;
      if (png == null || png.isEmpty) {
        return null;
      }
      final List<dynamic> rawMonitors =
          (result['monitors'] as List<dynamic>?) ?? <dynamic>[];
      return ScreenCapture(
        png: png,
        width: (result['width'] as num?)?.toInt() ?? 0,
        height: (result['height'] as num?)?.toInt() ?? 0,
        monitors: rawMonitors
            .whereType<Map<dynamic, dynamic>>()
            .map(
              (Map<dynamic, dynamic> m) => DjMonitor.fromMap(
                m.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
              ),
            )
            .toList(),
      );
    } on PlatformException {
      return null;
    } catch (_) {
      return null;
    }
  }
}
