// App launcher. Port of src/main/services/appLauncher.ts.
// Opens an installed app by name on Windows. Launch goes through
// SystemOps (platform channel) — never dart:io Process directly,
// so it works in the packaged app.
// Clock / reminder / alarm are NOT ported as working features
// (they live on the user's mobile for now); `clock` only launches
// the Windows Clock app.
import 'dart:io';

import 'system_ops.dart';

const Map<String, List<String>> appPaths = {
  'notepad': ['notepad.exe'],
  'chrome': [
    'chrome.exe',
    r'C:\Program Files\Google\Chrome\Application\chrome.exe',
    r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
  ],
  'calculator': ['calc.exe'],
  'paint': ['mspaint.exe'],
  'word': ['winword.exe'],
  'excel': ['excel.exe'],
  'powerpoint': ['powerpnt.exe'],
  'edge': [
    'msedge.exe',
    r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
  ],
  'vs code': ['code.exe'],
  'code': ['code.exe'],
  'spotify': ['spotify.exe'],
  'whatsapp': ['whatsapp.exe'],
  'explorer': ['explorer.exe'],
  'file explorer': ['explorer.exe'],
  'cmd': ['cmd.exe'],
  'terminal': ['wt.exe', 'cmd.exe'],
  'clock': ['clock.exe'],
};

class AppLauncher {
  final SystemOps systemOps;
  AppLauncher(this.systemOps);

  /// Open an installed app by name. Returns {ok, message}.
  Future<({bool ok, String message})> openApp(String name) async {
    final key = name.trim().toLowerCase();
    if (key == 'settings' && Platform.isWindows) {
      final result =
          await systemOps.openApp('cmd.exe', ['/c', 'start', 'ms-settings:']);
      if (!result.ok) {
        return (ok: false, message: 'I could not open Settings: ${result.message}');
      }
      return (ok: true, message: 'Opened Settings.');
    }
    final candidates = appPaths[key] ?? ['$key.exe'];
    String? found;
    for (final c in candidates) {
      if (_isAbsolute(c)) {
        try {
          if (File(c).statSync().type == FileSystemEntityType.file) {
            found = c;
            break;
          }
        } catch (_) {}
      } else if (findOnPath(c) != null) {
        found = c;
        break;
      }
    }
    if (found == null) {
      return (
        ok: false,
        message:
            "I could not find an app called '$name' on this laptop. Try the full name, like 'Google Chrome', or open it yourself once and tell me.",
      );
    }
    final exe = _isAbsolute(found) ? found : (findOnPath(found) ?? found);
    try {
      final result = await systemOps.openApp(exe, []);
      if (!result.ok) {
        return (ok: false, message: 'I found $key but could not open it: ${result.message}');
      }
      return (ok: true, message: 'Opened $key.');
    } catch (err) {
      return (ok: false, message: 'I found $key but could not open it: $err');
    }
  }

  /// Search PATH (+ PATHEXT on Windows) for [exe]. Null if not found.
  String? findOnPath(String exe) {
    final pathExt =
        Platform.isWindows ? (Platform.environment['PATHEXT'] ?? '.EXE') : '';
    final dirs = (Platform.environment['PATH'] ?? '')
        .split(Platform.pathSeparator == '\\' ? ';' : ':');
    for (final dir in dirs) {
      if (dir.isEmpty) continue;
      for (final ext in ['', ...pathExt.split(';')]) {
        final cand = '$dir${Platform.pathSeparator}$exe$ext';
        try {
          if (File(cand).statSync().type == FileSystemEntityType.file) {
            return cand;
          }
        } catch (_) {}
      }
    }
    return null;
  }
}

bool _isAbsolute(String p) =>
    RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p) ||
    p.startsWith(Platform.pathSeparator);
