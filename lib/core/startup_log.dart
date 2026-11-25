// Startup diagnostic log.
//
// Every launch appends timestamped lines to `dj_startup.log` next to
// the exe (same file the Windows runner writes to — see
// windows/runner/dj_startup_log.cpp), so one file shows both sides of
// a hung startup: whether Dart's main() ran, whether the first frame
// was built, and whether the native side saw that frame.
//
// Written synchronously with flush after every line, so lines survive
// a hang or a kill. Never throws: logging must never break startup.
import 'dart:io';

class StartupLog {
  static File? _file;

  static File? get _logFile {
    if (_file != null) return _file;
    try {
      final exe = Platform.resolvedExecutable;
      final sep = Platform.pathSeparator;
      final dir = exe.contains(sep)
          ? exe.substring(0, exe.lastIndexOf(sep))
          : '.';
      _file = File('$dir${sep}dj_startup.log');
    } catch (_) {
      _file = null;
    }
    return _file;
  }

  /// Append one `[time] step` line, flushed immediately.
  static void log(String step) {
    try {
      final file = _logFile;
      if (file == null) return;
      final now = DateTime.now();
      final stamp = now.toIso8601String();
      file.writeAsStringSync('[$stamp] dart: $step\n',
          mode: FileMode.append, flush: true);
    } catch (_) {
      // Logging is best-effort; a failed write must not break startup.
    }
  }
}
