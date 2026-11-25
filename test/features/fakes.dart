// Shared fakes for the HeyClicky feature tests. No real channels,
// no real apps, no network.

import 'package:dj/core/models.dart';
import 'package:dj/services/system_ops.dart';

class FakeSystemOps implements SystemOps {
  final List<String> openedApps = [];
  final List<String> openedUrls = [];

  @override
  Future<({bool ok, String message})> openApp(
    String exe,
    List<String> args,
  ) async {
    openedApps.add(exe);
    openedUrls.addAll(args);
    return (ok: true, message: 'Opened $exe.');
  }

  @override
  Future<({bool ok, String message})> openFile(String path) async =>
      (ok: true, message: 'Opened $path.');

  @override
  Future<({bool ok, String message})> openFolder(String path) async =>
      (ok: true, message: 'Opened the folder $path.');

  @override
  Future<void> deleteToTrash(List<String> paths) async {}

  @override
  Future<SystemStats> getSystemStats() async => SystemStats(
        cpuPercent: 10,
        cpuCores: 8,
        totalMemBytes: 1000,
        freeMemBytes: 500,
        uptimeSeconds: 60,
        platform: 'linux',
        checkedAt: DateTime.now().toIso8601String(),
      );

  @override
  Future<bool> setStartAtLogin(bool enabled) async => enabled;

  @override
  String getHomeDir() => '/home/test';

  @override
  Future<String?> pickFolder() async => null;
}

/// A SystemOps that refuses to open anything (for failure paths).
class FailingSystemOps extends FakeSystemOps {
  @override
  Future<({bool ok, String message})> openApp(
    String exe,
    List<String> args,
  ) async =>
      (ok: false, message: "I could not find an app called '$exe'.");
}
