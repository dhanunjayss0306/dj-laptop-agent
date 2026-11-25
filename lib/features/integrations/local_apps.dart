// Local apps integration — open an installed app by name, and list
// installed apps. No auth needed; always connected.
//
//   * Windows: opens apps through AppLauncher (the same known-apps
//     table as chat: notepad, chrome, calculator, ...). Listing scans
//     that table and reports which ones resolve on this laptop.
//   * Android: opening works through the system channel (by package
//     name or app label). LISTING on Android goes through the system
//     channel method 'listApps' — that method does NOT exist on the
//     Android native side yet (SystemChannelHandler has openApp but no
//     listApps), so listApps returns the plain message
//     'not available on Android yet' until the native side adds it.
//     Opening by name is unaffected.

import 'dart:io';

import 'package:flutter/services.dart';

import '../../services/app_launcher.dart';
import '../../services/system_ops.dart';
import 'integration.dart';

class LocalAppsIntegration extends Integration {
  LocalAppsIntegration({
    required SystemOps systemOps,
    AppLauncher? appLauncher,
    MethodChannel? systemChannel,
  })  : _launcher = appLauncher ?? AppLauncher(systemOps),
        _systemChannel = systemChannel ??
            const MethodChannel('com.dhanunjay.dj/system');

  final AppLauncher _launcher;
  final MethodChannel _systemChannel;

  @override
  String get id => 'local_apps';

  @override
  String get name => 'Local apps';

  @override
  String get description =>
      'Open an installed app by name, list installed apps. No sign-in.';

  @override
  bool get isConnected => true;

  @override
  Future<bool> connect() async => true;

  @override
  Future<void> disconnect() async {}

  @override
  List<IntegrationAction> get actions => [
        IntegrationAction(
          name: 'openApp',
          description: 'Open an installed app, e.g. {name: "notepad"}.',
          needsConnection: false,
          run: (args) async {
            final name = (args['name'] ?? '') as String;
            if (name.trim().isEmpty) return 'Give me an app name.';
            final result = await _launcher.openApp(name);
            return result.message;
          },
        ),
        IntegrationAction(
          name: 'listApps',
          description: 'List installed apps DJ can open.',
          needsConnection: false,
          run: (_) async => listApps(),
        ),
      ];

  /// Installed apps DJ can open, as plain names.
  Future<String> listApps() async {
    if (Platform.isWindows) {
      final found = <String>[];
      for (final name in appPaths.keys) {
        final candidates = appPaths[name]!;
        var ok = false;
        for (final c in candidates) {
          if (_isAbsolute(c)) {
            try {
              if (File(c).statSync().type == FileSystemEntityType.file) {
                ok = true;
                break;
              }
            } catch (_) {}
          } else if (_launcher.findOnPath(c) != null) {
            ok = true;
            break;
          }
        }
        if (ok) found.add(name);
      }
      if (found.isEmpty) return 'No known apps found on this laptop.';
      return found.map((n) => '• $n').join('\n');
    }
    // Android: ask the native side for the launchable apps.
    try {
      final result = await _systemChannel.invokeMethod<Map<dynamic, dynamic>>(
        'listApps',
      );
      final apps = result?['apps'];
      if (apps is List && apps.isNotEmpty) {
        return apps.map((a) => '• $a').join('\n');
      }
      return 'No launchable apps returned.';
    } on MissingPluginException {
      return 'Listing apps is not available on Android yet.';
    } on PlatformException {
      return 'Listing apps is not available on Android yet.';
    } catch (_) {
      return 'Listing apps is not available on Android yet.';
    }
  }
}

bool _isAbsolute(String p) =>
    RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p) ||
    p.startsWith(Platform.pathSeparator);
