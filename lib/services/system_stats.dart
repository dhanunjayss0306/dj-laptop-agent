// System stats. Port of src/main/services/systemStats.ts.
// Real numbers only: CPU % from two samples 500 ms apart (null
// when it cannot be measured — never invent a number). Disk usage
// is NOT included, same as Electron.
//
// On Linux this reads /proc directly (this VM). On Windows the
// platform plugin must supply the numbers via SystemOps — until
// then CPU is null and memory is 0 on non-Linux platforms, which
// the UI must render as "not measured", never as a real value.
import 'dart:io';

import '../core/models.dart';

class CpuSnapshot {
  final int idle;
  final int total;
  const CpuSnapshot({required this.idle, required this.total});
}

/// CPU use in percent between two snapshots. Null when the samples
/// are identical or went backwards (nothing to measure).
double? computeCpuPercent(CpuSnapshot prev, CpuSnapshot next) {
  final idleDelta = next.idle - prev.idle;
  final totalDelta = next.total - prev.total;
  if (totalDelta <= 0 || idleDelta < 0) return null;
  return ((totalDelta - idleDelta) / totalDelta * 1000).round() / 10;
}

CpuSnapshot? _snapshotLinuxCpus() {
  try {
    final lines = File('/proc/stat').readAsLinesSync();
    var idle = 0;
    var total = 0;
    for (final line in lines) {
      if (!line.startsWith('cpu') || line.startsWith('cpu ')) continue;
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length < 5) continue;
      final nums = parts
          .sublist(1)
          .map((s) => int.tryParse(s) ?? 0)
          .toList();
      if (nums.length < 4) continue;
      idle += nums[3] + (nums.length > 4 ? nums[4] : 0);
      total += nums.fold(0, (a, b) => a + b);
    }
    return CpuSnapshot(idle: idle, total: total);
  } catch (_) {
    return null;
  }
}

Future<double?> sampleCpuPercent([int delayMs = 500]) async {
  if (!Platform.isLinux) return null;
  final prev = _snapshotLinuxCpus();
  if (prev == null) return null;
  await Future<void>.delayed(Duration(milliseconds: delayMs));
  final next = _snapshotLinuxCpus();
  if (next == null) return null;
  return computeCpuPercent(prev, next);
}

int _linuxMem(String key) {
  try {
    for (final line in File('/proc/meminfo').readAsLinesSync()) {
      if (line.startsWith(key)) {
        final kb = int.tryParse(
                RegExp(r'(\d+)').firstMatch(line)?.group(1) ?? '') ??
            0;
        return kb * 1024;
      }
    }
  } catch (_) {}
  return 0;
}

int _linuxUptimeSeconds() {
  try {
    final s = File('/proc/uptime').readAsStringSync().split(' ').first;
    return double.tryParse(s)?.round() ?? 0;
  } catch (_) {
    return 0;
  }
}

/// Read the real system numbers. On Windows, prefer
/// SystemOps.getSystemStats() (platform channel) instead.
Future<SystemStats> readSystemStats() async {
  return SystemStats(
    cpuPercent: await sampleCpuPercent(),
    cpuCores: Platform.numberOfProcessors,
    totalMemBytes: Platform.isLinux ? _linuxMem('MemTotal:') : 0,
    freeMemBytes: Platform.isLinux ? _linuxMem('MemAvailable:') : 0,
    uptimeSeconds: Platform.isLinux ? _linuxUptimeSeconds() : 0,
    platform: '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    checkedAt: DateTime.now().toIso8601String(),
  );
}

/// Format uptime like the UI does: `2d 3h 14m` / `5h 12m` / `32m` / `45s`.
String formatUptime(int seconds) {
  final d = seconds ~/ 86400;
  final h = (seconds % 86400) ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  if (d > 0) return '${d}d ${h}h ${m}m';
  if (h > 0) return '${h}h ${m}m';
  if (m > 0) return '${m}m';
  return '${s}s';
}
