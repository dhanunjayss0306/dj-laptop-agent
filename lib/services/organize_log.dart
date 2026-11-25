// Shared _Organizer_Log.csv writer (Organize + Duplicates).
// Header `Name,OldPath,NewPath,Date` when the file is created; rows
// CSV-quoted with `"` doubled. A log-write failure is reported as
// an error, not silently ignored.
import 'dart:io';

const String organizerLog = '_Organizer_Log.csv';

/// Append [rows] to the log at [logPath]. Returns an error string, or null.
String? appendOrganizerLog(String logPath, List<List<String>> rows) {
  try {
    final file = File(logPath);
    final writeHeader = !file.existsSync();
    final lines = <String>[];
    if (writeHeader) lines.add('Name,OldPath,NewPath,Date');
    for (final row in rows) {
      lines.add(row
          .map((c) => '"${c.replaceAll('"', '""')}"')
          .join(','));
    }
    file.writeAsStringSync('${lines.join('\n')}\n',
        mode: FileMode.append, flush: true);
    return null;
  } catch (err) {
    return 'Could not write the log: $err';
  }
}

String todayIso() => DateTime.now().toIso8601String().substring(0, 10);
