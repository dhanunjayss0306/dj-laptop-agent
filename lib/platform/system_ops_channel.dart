// DJ Windows platform channel: SystemOps implementation.
//
// Implements the SystemOps interface owned by the Core agent at
// package:dj/services/system_ops.dart. This file defines NO abstract class
// of its own; it only adapts that interface to the native Windows runner
// over the MethodChannel 'com.dhanunjay.dj/system'.
//
// The interface this file targets (as used by the Core services and their
// tests — lib/services/app_launcher.dart, chat_service.dart,
// duplicate_service.dart, test/core/dj_index_chat_test.dart):
//   Future<({bool ok, String message})> openFile(String path)
//   Future<({bool ok, String message})> openFolder(String path)
//   Future<({bool ok, String message})> openApp(String exe, List<String> args)
//   Future<void> deleteToTrash(List<String> paths)  // Recycle Bin only
//   Future<SystemStats> getSystemStats()
//   Future<bool> setStartAtLogin(bool enabled)
//   String getHomeDir()                             // synchronous
//   Future<String?> pickFolder()
//
// Channel contract (native side: windows/runner/dj_system_channel.cpp):
// every method replies with a Map: {'ok': true, ...data} or
// {'ok': false, 'message': ...}. This class converts those maps to the
// typed returns above. Where the return type has no room for an error
// (deleteToTrash, getSystemStats, setStartAtLogin) a native failure
// throws a PlatformException instead of inventing a result — the Core
// callers catch it and report it. Record-returning methods carry the
// error in the record and never throw.
//
// getHomeDir() is synchronous by interface design, so it cannot await
// the channel. It returns the native channel's value once warmed (fetched
// in the background at construction), falling back to the USERPROFILE
// environment variable, which names the same folder on Windows.
//
// Incoming calls from native: the runner invokes 'onTrayHidden' on this
// channel the first time the window hides into the tray. Set [onTrayHidden]
// to receive it (the Dart side owns the "show once" flag in dj_config.json).

import 'dart:async';
import 'dart:io' show Platform;

import 'package:dj/core/models.dart';
import 'package:flutter/services.dart';

import 'package:dj/services/system_ops.dart';

/// MethodChannel implementation of [SystemOps] for Windows.
class SystemOpsChannel implements SystemOps {
  SystemOpsChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName) {
    _channel.setMethodCallHandler(_handleNativeCall);
    // Warm the sync getHomeDir() cache in the background.
    unawaited(_refreshHomeDir());
  }

  static const String _channelName = 'com.dhanunjay.dj/system';

  final MethodChannel _channel;

  /// Called by native code the first time the window hides into the tray.
  /// The Dart side decides whether to show the one-time tray note.
  void Function()? onTrayHidden;

  String? _homeCache;

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method == 'onTrayHidden') {
      onTrayHidden?.call();
    }
    // Unknown incoming calls are ignored.
  }

  Future<void> _refreshHomeDir() async {
    final Map<String, dynamic> result = await _invoke('getHomeDir');
    final String? path = result['path'] as String?;
    if (path != null && path.isNotEmpty) {
      _homeCache = path;
    }
  }

  /// Invokes [method] and normalises the reply to a Map.
  /// Never throws: every failure becomes {'ok': false, 'message': ...}.
  Future<Map<String, dynamic>> _invoke(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    try {
      final Map<dynamic, dynamic>? result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>(method, arguments);
      if (result == null) {
        return <String, dynamic>{
          'ok': false,
          'message': 'No reply from Windows for $method.',
        };
      }
      final Map<String, dynamic> out = <String, dynamic>{};
      for (final MapEntry<dynamic, dynamic> entry in result.entries) {
        out[entry.key.toString()] = entry.value;
      }
      out.putIfAbsent('ok', () => true);
      return out;
    } on PlatformException catch (e) {
      return <String, dynamic>{
        'ok': false,
        'message': e.message ?? e.toString(),
      };
    } catch (e) {
      return <String, dynamic>{'ok': false, 'message': e.toString()};
    }
  }

  ({bool ok, String message}) _toResult(
    Map<String, dynamic> map,
    String fallbackMessage,
  ) {
    final bool ok = map['ok'] == true;
    final String? message = map['message'] as String?;
    return (
      ok: ok,
      message: (message != null && message.isNotEmpty)
          ? message
          : fallbackMessage,
    );
  }

  @override
  Future<({bool ok, String message})> openFile(String path) async {
    final Map<String, dynamic> result =
        await _invoke('openFile', <String, dynamic>{'path': path});
    return _toResult(result, 'I could not open that file.');
  }

  @override
  Future<({bool ok, String message})> openFolder(String path) async {
    final Map<String, dynamic> result =
        await _invoke('openFolder', <String, dynamic>{'path': path});
    return _toResult(result, 'I could not open that folder.');
  }

  @override
  Future<({bool ok, String message})> openApp(
    String exe,
    List<String> args,
  ) async {
    final Map<String, dynamic> result = await _invoke(
      'openApp',
      <String, dynamic>{'exe': exe, 'args': args},
    );
    return _toResult(result, "I could not find an app called '$exe'.");
  }

  @override
  Future<void> deleteToTrash(List<String> paths) async {
    // Native side uses SHFileOperationW with FOF_ALLOWUNDO (Recycle Bin)
    // for the whole list in one call, like Electron's single trash() call.
    // There is no permanent-delete path in DJ.
    if (paths.isEmpty) {
      return;
    }
    final Map<String, dynamic> result =
        await _invoke('deleteToTrash', <String, dynamic>{'paths': paths});
    if (result['ok'] != true) {
      throw PlatformException(
        code: 'deleteToTrash',
        message: (result['message'] as String?) ??
            'Could not move files to the Recycle Bin.',
      );
    }
  }

  @override
  Future<SystemStats> getSystemStats() async {
    final Map<String, dynamic> result = await _invoke('getSystemStats');
    if (result['ok'] != true) {
      throw PlatformException(
        code: 'getSystemStats',
        message: (result['message'] as String?) ??
            'Could not read system stats.',
      );
    }
    return SystemStats.fromJson(<String, dynamic>{
      ...result,
      'checkedAt': DateTime.now().toIso8601String(),
    });
  }

  @override
  Future<bool> setStartAtLogin(bool enabled) async {
    final Map<String, dynamic> result = await _invoke(
      'setStartAtLogin',
      <String, dynamic>{'enabled': enabled},
    );
    if (result['ok'] != true) {
      throw PlatformException(
        code: 'setStartAtLogin',
        message: (result['message'] as String?) ??
            'Could not change start-at-login.',
      );
    }
    return (result['enabled'] as bool?) ?? enabled;
  }

  @override
  String getHomeDir() {
    // Synchronous by interface design: cached native value first, then
    // USERPROFILE (the same folder on Windows), then empty.
    return _homeCache ?? Platform.environment['USERPROFILE'] ?? '';
  }

  @override
  Future<String?> pickFolder() async {
    // Native returns {'ok': true, 'path': <dir>} or
    // {'ok': false, 'message': 'cancelled', 'path': null} on cancel.
    final Map<String, dynamic> result = await _invoke('pickFolder');
    if (result['ok'] != true) {
      return null;
    }
    return result['path'] as String?;
  }

  /// Downloads folder via the native channel. NOT part of the SystemOps
  /// interface (Core resolves Downloads from the home dir); provided
  /// because the native channel supports it (SHGetKnownFolderPath
  /// FOLDERID_Downloads). Returns null when it cannot be determined.
  Future<String?> getDownloadsDir() async {
    final Map<String, dynamic> result = await _invoke('getDownloadsDir');
    if (result['ok'] != true) {
      return null;
    }
    return result['path'] as String?;
  }
}
