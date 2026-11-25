import 'package:flutter/services.dart';

/// Dart-side helper for DJ's Android AccessibilityService (real input:
/// tap / swipe / type / Back-Home-Recents, channel `com.dhanunjay.dj/input`).
///
/// The service must be enabled by hand, once, in
/// Settings → Accessibility → DJ. Use [isAccessibilityEnabled] to check and
/// [openAccessibilitySettings] to deep-link the user to the right page.
///
/// This file intentionally contains only these two helpers. The SystemOps
/// interface lives in lib/services/system_ops.dart (Core agent) and its
/// MethodChannel implementation in lib/platform/system_ops_channel.dart
/// (Windows agent) — one Dart implementation serves both platforms, so no
/// Android-only SystemOps class exists here.
class AndroidAccessibility {
  AndroidAccessibility._();

  static const MethodChannel _inputChannel =
      MethodChannel('com.dhanunjay.dj/input');

  /// True when the DJ accessibility service is switched on in Settings.
  /// Returns false (never throws) when the channel is unavailable, e.g. on
  /// Windows or before the native side is registered.
  static Future<bool> isAccessibilityEnabled() async {
    try {
      final Map<String, dynamic>? result = await _inputChannel
          .invokeMapMethod<String, dynamic>('isAccessibilityEnabled');
      return result?['enabled'] == true;
    } on PlatformException {
      return false;
    }
  }

  /// Opens Settings → Accessibility so the user can turn on DJ.
  /// The service appears there under installed / downloaded services as "DJ".
  static Future<void> openAccessibilitySettings() async {
    await _inputChannel.invokeMethod<void>('openAccessibilitySettings');
  }
}
