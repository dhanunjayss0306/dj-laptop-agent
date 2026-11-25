// Window operations for the Privacy Screen blackout.
//
// Design ported from SafeScreen by kv4u (MIT) — see THIRD_PARTY_NOTICES.md.
//
// The blackout is DJ's own window, expanded: on one display it goes
// full-screen (exact, and it hides the taskbar); on several displays it
// spans the union of all of them (see display_geometry.dart). When the
// user is looking again, the window returns to the panel bounds it had
// before the blackout.
//
// Two deliberate differences from SafeScreen, because DJ is not a
// dedicated protection app:
//   * SafeScreen keeps its window always-on-top even as a panel. DJ
//     does not: always-on-top is set only while blacked out, and cleared
//     when the panel returns, so DJ behaves like a normal app window.
//   * SafeScreen restores a fixed panel size, centred. DJ restores the
//     exact bounds the window had before the blackout, so the window
//     goes back where the user left it.
//
// The real implementation uses window_manager + screen_retriever and is
// Windows-only. The controller depends only on the abstract class, so
// tests use the fake below via [PrivacyWindowOps.noop].

import 'dart:io';
import 'dart:ui';

import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'display_geometry.dart';

/// Window operations the Privacy Screen controller needs.
abstract class PrivacyWindowOps {
  /// The real implementation (window_manager + screen_retriever).
  factory PrivacyWindowOps.real() = _RealPrivacyWindowOps;

  /// Does nothing. Used on non-Windows platforms and in tests.
  factory PrivacyWindowOps.noop() = _NoopPrivacyWindowOps;

  /// True while the window is showing the blackout.
  bool get isBlackedOut;

  /// Records the panel bounds to return to. Call when protection
  /// starts, while the window is still a normal panel.
  Future<void> preparePanel();

  /// Expands the window into the blackout (full-screen on one display,
  /// spanning all displays on several). Always-on-top while blacked
  /// out, so no other window can cover it.
  Future<void> showBlackout();

  /// Returns the window to the panel bounds recorded by [preparePanel]
  /// (or the last blackout), clears always-on-top, and focuses it.
  /// When the window was hidden before the blackout, it is hidden
  /// again instead of being shown.
  Future<void> restorePanel();

  /// Whether the window is currently visible.
  Future<bool> isVisible();

  /// Shows and focuses the window.
  Future<void> showAndFocus();

  /// Hides the window (into the tray, when DJ has one).
  Future<void> hide();
}

class _RealPrivacyWindowOps implements PrivacyWindowOps {
  bool _blackedOut = false;
  Rect? _panelBounds;
  bool _hiddenBeforeBlackout = false;

  @override
  bool get isBlackedOut => _blackedOut;

  @override
  Future<void> preparePanel() async {
    if (!Platform.isWindows) return;
    try {
      _panelBounds = await windowManager.getBounds();
    } catch (_) {
      _panelBounds = null;
    }
  }

  @override
  Future<void> showBlackout() async {
    if (!Platform.isWindows) return;
    if (_blackedOut) return;
    try {
      _hiddenBeforeBlackout = !(await windowManager.isVisible());
      _panelBounds ??= await windowManager.getBounds();
      await windowManager.show();
      await _coverAllDisplays();
      await windowManager.setAlwaysOnTop(true);
      await windowManager.focus();
      _blackedOut = true;
    } catch (e) {
      // A failed blackout must not leave DJ half-expanded. The caller
      // treats a failed apply as an error and keeps protection on.
      rethrow;
    }
  }

  /// Expands the blackout across every display.
  ///
  /// `setFullScreen` only ever covers the monitor the window happens
  /// to be on, so on a multi-monitor desk every other screen would stay
  /// perfectly readable while the user is away. That is the hole this
  /// closes.
  ///
  /// A single display keeps the setFullScreen path: it is exact, and
  /// unlike a spanning window it also hides the taskbar.
  Future<void> _coverAllDisplays() async {
    List<Display> displays = const <Display>[];
    try {
      displays = await screenRetriever.getAllDisplays();
    } catch (_) {
      displays = const <Display>[];
    }

    if (displays.length < 2) {
      await windowManager.setFullScreen(true);
      return;
    }

    final CoverRect? cover = computeCoverRect(
      displays.map((Display d) {
        final Offset origin = d.visiblePosition ?? Offset.zero;
        return DisplayBounds(
          left: origin.dx,
          top: origin.dy,
          width: d.size.width,
          height: d.size.height,
          scaleFactor: (d.scaleFactor ?? 1).toDouble(),
        );
      }).toList(),
      windowScaleFactor: windowManager.getDevicePixelRatio(),
    );

    // Never trust a nonsensical rectangle. A bad cover is worse than a
    // single-monitor one, because it could leave the primary screen bare
    // while the app believes it is protected.
    if (cover == null || cover.width < 200 || cover.height < 200) {
      await windowManager.setFullScreen(true);
      return;
    }

    await windowManager.setFullScreen(false);
    await windowManager.setBounds(
      Rect.fromLTWH(cover.left, cover.top, cover.width, cover.height),
    );
  }

  @override
  Future<void> restorePanel() async {
    if (!Platform.isWindows) return;
    if (!_blackedOut) return;
    _blackedOut = false;
    try {
      await windowManager.setFullScreen(false);
      await windowManager.setAlwaysOnTop(false);
      if (_hiddenBeforeBlackout) {
        // The window was hidden (in the tray) before the blackout.
        // Return it to where it was instead of popping it up.
        await windowManager.hide();
        return;
      }
      final Rect bounds = _panelBounds ?? _defaultPanelBounds();
      await windowManager.setBounds(bounds);
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {
      // Best effort: a failed restore must not leave the screen black.
      try {
        await windowManager.setFullScreen(false);
        await windowManager.setAlwaysOnTop(false);
        await windowManager.show();
      } catch (_) {}
    }
  }

  /// The DJ window size from windows/runner/main.cpp, centred.
  Rect _defaultPanelBounds() {
    const double width = 880;
    const double height = 720;
    final Size screen = PlatformDispatcher.instance.views.first.physicalSize /
        PlatformDispatcher.instance.views.first.devicePixelRatio;
    return Rect.fromLTWH(
      (screen.width - width) / 2,
      (screen.height - height) / 2,
      width,
      height,
    );
  }

  @override
  Future<bool> isVisible() async {
    if (!Platform.isWindows) return false;
    try {
      return await windowManager.isVisible();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> showAndFocus() async {
    if (!Platform.isWindows) return;
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {}
  }

  @override
  Future<void> hide() async {
    if (!Platform.isWindows) return;
    try {
      await windowManager.hide();
    } catch (_) {}
  }
}

class _NoopPrivacyWindowOps implements PrivacyWindowOps {
  @override
  bool get isBlackedOut => false;

  @override
  Future<void> preparePanel() async {}

  @override
  Future<void> showBlackout() async {}

  @override
  Future<void> restorePanel() async {}

  @override
  Future<bool> isVisible() async => false;

  @override
  Future<void> showAndFocus() async {}

  @override
  Future<void> hide() async {}
}
