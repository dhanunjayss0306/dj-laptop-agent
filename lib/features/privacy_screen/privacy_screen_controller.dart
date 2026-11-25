// Privacy Screen controller: the single place that decides whether the
// screen is shown.
//
// Design ported from SafeScreen by kv4u (MIT) — see THIRD_PARTY_NOTICES.md.
//
// The controller owns the rule, not the pixels:
//   * the gaze detector says whether the user is present and attentive
//     (see gaze_detector.dart — fail-closed, hide fast, reveal slow);
//   * this controller combines that with the override and the running
//     state into one boolean, [_blackoutWanted], and drives the window
//     through [PrivacyWindowOps].
//
// ── The override ─────────────────────────────────────────────────────────
//
// Ctrl+Alt+P is a GLOBAL hotkey (Windows RegisterHotKey, native id 2 —
// see windows/runner/dj_hotkey.cpp), so it fires even when the screen is
// blacked out and DJ does not have focus. One press reveals the screen
// immediately (override ON), even without face detection, even if a
// second face is in view — for when he looked away and does not want to
// look back at the camera, or someone else is legitimately watching with
// him. A second press turns the override off and protection resumes
// under the normal face-detection rules.
//
// ONLY this shortcut reveals the screen. There is no "press any key"
// path anywhere in this feature: a stray keypress must not defeat the
// privacy (anyone bumping the keyboard could reveal it). The override
// state is always visible: this controller's [statusMessage] is shown on
// the Privacy Screen page and in the HomeShell banner while it is on.
//
// The shortcut is fixed at Ctrl+Alt+P. Making it configurable would
// need a key-capture UI and re-registration; the page says so plainly
// instead. It does not clash with DJ's other global hotkey (Ctrl+Alt+D,
// native id 1) or anything else in DJ.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../platform/hotkey_channel.dart';
import 'gaze_detector.dart';
import 'privacy_screen_service.dart';
import 'privacy_window_ops.dart';

/// Persisted Privacy Screen settings (stored in AppConfig).
class PrivacyScreenSettings {
  const PrivacyScreenSettings({
    this.sensitivity = 0.75,
    this.detectShoulderSurfers = true,
    this.startOnLaunch = false,
  });

  /// 0.0 = lenient, 1.0 = strict. Default 0.75 (SafeScreen's default).
  final double sensitivity;

  /// When true, a second face in frame protects the screen.
  final bool detectShoulderSurfers;

  /// Start protection automatically when DJ starts.
  final bool startOnLaunch;

  PrivacyScreenSettings copyWith({
    double? sensitivity,
    bool? detectShoulderSurfers,
    bool? startOnLaunch,
  }) =>
      PrivacyScreenSettings(
        sensitivity: sensitivity ?? this.sensitivity,
        detectShoulderSurfers:
            detectShoulderSurfers ?? this.detectShoulderSurfers,
        startOnLaunch: startOnLaunch ?? this.startOnLaunch,
      );
}

/// The fixed override shortcut. Ctrl+Alt+P (vk 0x50, 'P').
/// See the file header for why it is fixed and why it is safe.
const String kPrivacyOverrideShortcut = 'Ctrl+Alt+P';

/// Shown while the override is on, on the Privacy Screen page and in
/// the HomeShell banner, so he always knows protection is off.
const String kPrivacyOverrideMessage =
    'Privacy paused — press Ctrl+Alt+P to resume';

class PrivacyScreenController extends ChangeNotifier {
  PrivacyScreenController({
    required PrivacyScreenSettings settings,
    GazeDetectorService? gazeDetector,
    PrivacyScreenService? service,
    PrivacyWindowOps? windowOps,
    HotkeyChannel? hotkeyChannel,
    this.onSettingsChanged,
    // Test seam: defaults to the real platform. Tests pass true to
    // exercise the running-state flow on a non-Windows machine.
    bool? isWindows,
  })  : _settings = settings,
        _isWindows = isWindows ?? Platform.isWindows,
        gazeDetector = gazeDetector ??
            GazeDetectorService(
              sensitivity: settings.sensitivity,
              detectShoulderSurfers: settings.detectShoulderSurfers,
            ),
        windowOps = windowOps ?? PrivacyWindowOps.real() {
    this.service = service ??
        PrivacyScreenService(
          gazeDetector: this.gazeDetector,
        );
    // Wired here, not only when the controller creates the service, so
    // an injected service (tests) behaves the same as the real one.
    this.service.onGazeStateChanged = () => _applyWindowMode();
    this.service.onError = (message) {
      _error = message;
      notifyListeners();
    };
    _hotkeyChannel = hotkeyChannel;
  }

  final GazeDetectorService gazeDetector;
  late final PrivacyScreenService service;
  final PrivacyWindowOps windowOps;

  /// Whether this is Windows. The feature is Windows-only; on any
  /// other platform the controller reports laptop-only and never starts
  /// the camera. (Injectable for tests; defaults to the real platform.)
  final bool _isWindows;

  /// Called whenever a setting changes, so the caller can persist it.
  final void Function(PrivacyScreenSettings settings)? onSettingsChanged;

  PrivacyScreenSettings _settings;
  PrivacyScreenSettings get settings => _settings;

  HotkeyChannel? _hotkeyChannel;
  StreamSubscription<void>? _hotkeySub;

  bool _running = false;
  bool _starting = false;
  bool _overrideOn = false;
  bool _blackoutActive = false;
  String? _error;

  /// The override hotkey (Ctrl+Alt+P) could not be registered — for
  /// example another app already uses it. The page shows this; the
  /// Start/Stop button and the Resume button still work.
  String? _hotkeyError;

  bool _initialized = false;
  bool _disposed = false;

  // ── State ────────────────────────────────────────────────────────────

  bool get isRunning => _running;
  bool get isStarting => _starting;
  bool get isOverrideOn => _overrideOn;

  /// True while the window is actually showing the blackout.
  bool get isBlackedOut => _blackoutActive;

  /// True while protection is on and the screen is actually hidden.
  bool get isProtected => _running && _blackoutActive && !_overrideOn;

  /// Last error, or null. Shown on the page in plain words.
  String? get error => _error;

  String? get hotkeyError => _hotkeyError;

  /// One-line status for the page and the shell banner.
  String get statusMessage {
    if (!_running) return 'Protection off';
    if (_overrideOn) return kPrivacyOverrideMessage;
    if (_error != null) return _error!;
    if (_blackoutActive) {
      return 'Protected — ${gazeDetector.reason.message}';
    }
    return 'Looking at screen';
  }

  /// The screen is black exactly when protection is running, the
  /// override is off, and the gaze detector has not confirmed the user
  /// is present and attentive. The gaze detector starts protected, so
  /// the screen blacks the moment protection starts, until the camera
  /// proves the user is looking.
  bool get _blackoutWanted =>
      _running && !_overrideOn && !gazeDetector.isScreenVisible;

  // ── Lifecycle ────────────────────────────────────────────────────────

  /// Registers the Ctrl+Alt+P override hotkey (Windows only) and starts
  /// protection when [PrivacyScreenSettings.startOnLaunch] is set.
  /// Safe to call more than once; later calls are no-ops.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    if (_isWindows && _hotkeyChannel != null) {
      _hotkeySub =
          _hotkeyChannel!.onPrivacyHotkeyPressed.listen((_) {
        toggleOverride();
      });
      final bool ok = await _hotkeyChannel!.registerPrivacyHotkey();
      if (!ok) {
        _hotkeyError =
            'Ctrl+Alt+P is already used by another app, so the override '
            'shortcut is unavailable. Start, Stop and Resume on this page '
            'still work.';
        notifyListeners();
      }
    }
    if (_settings.startOnLaunch && _isWindows) {
      await startProtection();
    }
  }

  /// Starts the camera and the detection loop. Windows only; on any
  /// other platform this sets the laptop-only message and returns.
  Future<void> startProtection() async {
    if (_running || _starting) return;
    if (!_isWindows) {
      _error =
          'Privacy Screen is laptop-only. It needs a Windows laptop with '
          'a webcam.';
      notifyListeners();
      return;
    }
    _starting = true;
    _error = null;
    notifyListeners();
    gazeDetector.reset();
    await windowOps.preparePanel();
    await service.start();
    _starting = false;
    if (_error != null) {
      // The service reported a failure (no camera, camera busy,
      // detector failed). Stay off rather than half-on.
      notifyListeners();
      return;
    }
    _running = true;
    notifyListeners();
    // Blacks out immediately: the gaze detector starts protected and
    // only reveals after several good frames.
    await _applyWindowMode();
  }

  /// Stops the camera and returns the window to its panel bounds.
  Future<void> stopProtection() async {
    if (!_running && !_starting) return;
    _running = false;
    _starting = false;
    _overrideOn = false;
    await service.stop();
    gazeDetector.reset();
    await windowOps.restorePanel();
    _blackoutActive = windowOps.isBlackedOut;
    _error = null;
    notifyListeners();
  }

  // ── Override (Ctrl+Alt+P) ────────────────────────────────────────────

  /// Toggles the override. Only meaningful while protection is running;
  /// returns false (and does nothing) otherwise. Turning it on reveals
  /// the screen immediately; turning it off resumes normal
  /// face-detection rules. Returns the new override state.
  bool toggleOverride() {
    if (!_running) return false;
    _overrideOn = !_overrideOn;
    // Apply immediately; do not wait for the next camera frame.
    unawaited(_applyWindowMode());
    notifyListeners();
    return _overrideOn;
  }

  /// Sets the override explicitly (used by the Resume button).
  void setOverride(bool value) {
    if (!_running || _overrideOn == value) return;
    _overrideOn = value;
    unawaited(_applyWindowMode());
    notifyListeners();
  }

  // ── Settings ─────────────────────────────────────────────────────────

  void setSensitivity(double value) {
    final double clamped = value.clamp(0.0, 1.0);
    _settings = _settings.copyWith(sensitivity: clamped);
    gazeDetector.setSensitivity(clamped);
    onSettingsChanged?.call(_settings);
    notifyListeners();
  }

  void setDetectShoulderSurfers(bool value) {
    _settings = _settings.copyWith(detectShoulderSurfers: value);
    gazeDetector.detectShoulderSurfers = value;
    onSettingsChanged?.call(_settings);
    notifyListeners();
  }

  void setStartOnLaunch(bool value) {
    _settings = _settings.copyWith(startOnLaunch: value);
    onSettingsChanged?.call(_settings);
    notifyListeners();
  }

  // ── Window mode ──────────────────────────────────────────────────────

  // Window operations are serialised: a gaze change that arrives while
  // one is in flight is applied right after it, never concurrently.
  bool _applyingWindowMode = false;
  bool _windowModeDirty = false;

  Future<void> _applyWindowMode() async {
    if (_applyingWindowMode) {
      _windowModeDirty = true;
      return;
    }
    _applyingWindowMode = true;
    try {
      while (true) {
        _windowModeDirty = false;
        final bool want = _blackoutWanted;
        if (want && !windowOps.isBlackedOut) {
          await windowOps.showBlackout();
        } else if (!want && windowOps.isBlackedOut) {
          await windowOps.restorePanel();
        }
        _blackoutActive = windowOps.isBlackedOut;
        notifyListeners();
        if (!_windowModeDirty) break;
      }
    } catch (e) {
      // A failed blackout/restore is reported plainly. The gaze
      // detector still fails closed; only the window move failed.
      _error = 'Could not change the screen: $e';
      notifyListeners();
    } finally {
      _applyingWindowMode = false;
    }
  }

  @override
  void notifyListeners() {
    // The async shutdown in _disposeAsync can finish after dispose();
    // notifying a disposed ChangeNotifier throws, so swallow it.
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    // ChangeNotifier.dispose is synchronous; the async cleanup runs
    // unawaited, which is fine at shutdown. _disposed stops the
    // cleanup's notifyListeners from throwing after dispose.
    _disposed = true;
    unawaited(_disposeAsync());
    super.dispose();
  }

  Future<void> _disposeAsync() async {
    await _hotkeySub?.cancel();
    if (_isWindows) {
      try {
        await _hotkeyChannel?.unregisterPrivacyHotkey();
      } catch (_) {}
    }
    await stopProtection();
  }
}
