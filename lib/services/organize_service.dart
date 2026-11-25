// Organize Downloads. Port of src/main/services/organizeService.ts.
// Plan then confirm: plan() moves nothing; apply() moves only on
// Yes, never deletes, never overwrites (freePath -1, -2, ...).
// Scope: files directly in ~/Downloads only. Date filter uses mtime.
import 'dart:io';

import '../core/brain.dart';
import '../core/models.dart';
import 'organize_log.dart';

String _sep = Platform.pathSeparator;

String _joinPath(List<String> parts) => parts.join(_sep);

/// Keyword folders, in exact order. First match wins.
const List<({List<String> folder, List<String> words})> keywordFolders = [
  (
    folder: ['_Private-DoNotShare'],
    words: ['credentials', 'recovery-codes', 'recovery codes', 'atlas-credentials'],
  ),
  (
    folder: ['Hackathons', 'SAPSS-Vishwakarma'],
    words: [
      'sapss', 'saps', 'vishwakarma', 'smart public', 'public sanitation',
      'sanitation', 'toilet', 'pulse box', 'pulse_box',
    ],
  ),
  (
    folder: ['Hackathons', 'SasyaSakhi-AgriTech'],
    words: [
      'sasyasakhi', 'soilsaathi', 'soil', 'smart farm', 'smart farming',
      'agritech', 'agri', 'crop', 'farmer', 'saiya', 'sasya',
    ],
  ),
  (
    folder: ['Hackathons', 'Virun-Travel'],
    words: [
      'virun', 'yatra', 'yatrasetu', 'travel titan', 'traveltitans',
      'localmate', 'tourism', 'tourist', 'samartha', 'nataraj', 'hatra',
    ],
  ),
  (folder: ['Hackathons', 'GlobalTap'], words: ['globaltap', 'global tap']),
  (folder: ['Hackathons', 'Persona'], words: ['persona']),
  (folder: ['Hackathons', 'Quantum'], words: ['quantum']),
  (
    folder: ['Hackathons', 'HackerRank'],
    words: ['hackerrank', 'ghost data', 'hacerrank'],
  ),
  (folder: ['Hackathons', 'VRGym'], words: ['vrgym', 'vr gym', 'vr-gym']),
  (folder: ['Projects', 'Chaiya'], words: ['chaiya']),
  (folder: ['Projects', 'Health'], words: ['patient', 'health concern']),
  (
    folder: ['College'],
    words: [
      'ada', 'assignment', 'employee dataset', 'startup summit',
      'idea presentation', 'coa', 'oopj', 'os-lab', 'os lab', 'probability',
      'book list', 'exam prep', 'multiplexer', 'demultiplexer',
      'experiment', 'lab manual',
    ],
  ),
];

const Map<String, List<String>> typeFolders = {
  'Programs': ['.exe', '.msi'],
  'Movies': ['.mp4', '.mkv', '.avi', '.mov', '.webm'],
  'Music': ['.mp3', '.wav', '.flac', '.aac'],
  'Images': ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.heic', '.svg', '.jfif', '.bmp'],
  'Documents': ['.pdf', '.docx', '.doc', '.txt', '.md'],
  'Spreadsheets': ['.xlsx', '.xls', '.csv'],
  'Presentations': ['.pptx', '.ppt'],
  'Code': ['.py', '.js', '.ts', '.jsx', '.tsx', '.html', '.css', '.json', '.ipynb', '.dxf'],
  'Archives': ['.zip', '.rar', '.7z', '.tar', '.gz'],
};

/// Files the organizer never touches.
const Set<String> organizerSkip = {
  'organize-downloads.ps1',
  '_organizer_log.csv',
  'downloads-preview.csv',
};

/// Where one file goes, using the same rules as the .ps1 script.
List<String> destinationFolder(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.env')) return ['_Private-DoNotShare'];
  for (final entry in keywordFolders) {
    for (final word in entry.words) {
      if (lower.contains(word)) return entry.folder;
    }
  }
  if (lower.contains('whatsapp image')) return ['Images', 'WhatsApp'];
  if (lower.contains('chatgpt image')) return ['Images', 'ChatGPT'];
  if (lower.contains('screenshot')) return ['Images'];
  final ext = _ext(name);
  for (final entry in typeFolders.entries) {
    if (entry.value.contains(ext)) return [entry.key];
  }
  return ['_Review'];
}

/// A destination path that never overwrites: adds -1, -2, ...
String freePath(String destFolder, String name) {
  var dest = _joinPath([destFolder, name]);
  if (!File(dest).existsSync() && !Directory(dest).existsSync()) return dest;
  final ext = _ext(name);
  final stem = ext.isEmpty ? name : name.substring(0, name.length - ext.length);
  var n = 1;
  for (;;) {
    final cand = _joinPath([destFolder, '$stem-$n$ext']);
    if (!File(cand).existsSync() && !Directory(cand).existsSync()) return cand;
    n += 1;
  }
}

String _ext(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot).toLowerCase();
}

Set<String>? _rangeDates(OrganizeRange range, [DateTime? now]) {
  final today = now ?? DateTime.now();
  String key(DateTime d) => d.toIso8601String().substring(0, 10);
  DateTime addDays(DateTime d, int n) => d.add(Duration(days: n));
  switch (range) {
    case OrganizeRangeToday():
      return {key(today)};
    case OrganizeRangeYesterday():
      return {key(addDays(today, -1))};
    case OrganizeRangeLastDays(:final days):
      // "last N days" means today and the N days before it.
      return {for (var i = 0; i <= days; i++) key(addDays(today, -i))};
    case OrganizeRangeAll():
      return null;
  }
}

String organizeLabel(OrganizeRange range) => rangeLabel(range);

class OrganizeService {
  /// Plan a Downloads tidy-up for a date range. Moves NOTHING.
  /// Only files directly in Downloads in that range.
  List<OrganizeMove> plan(String downloadsDir, OrganizeRange range,
      [DateTime? now]) {
    final dir = Directory(downloadsDir);
    if (!dir.existsSync()) return [];
    final dates = _rangeDates(range, now);
    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync();
    } catch (_) {
      return [];
    }
    final names = entries
        .whereType<File>()
        .map((f) => f.path.split(_sep).last)
        .toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final plan = <OrganizeMove>[];
    for (final name in names) {
      if (organizerSkip.contains(name.toLowerCase())) continue;
      final full = _joinPath([downloadsDir, name]);
      DateTime mtime;
      try {
        mtime = File(full).statSync().modified;
      } catch (_) {
        continue;
      }
      if (dates != null && !dates.contains(mtime.toIso8601String().substring(0, 10))) {
        continue;
      }
      final folderParts = destinationFolder(name);
      final destFolder = _joinPath([downloadsDir, ...folderParts]);
      final dest = freePath(destFolder, name);
      plan.add(OrganizeMove(
        name: name,
        old: full,
        newPath: dest,
        folder: folderParts.join(_sep),
      ));
    }
    return plan;
  }

  /// Carry out a plan. Move only, never delete, never overwrite.
  /// Every move is written to _Organizer_Log.csv in Downloads.
  ({List<OrganizeMove> moved, List<String> errors, String logPath}) apply(
      List<OrganizeMove> plan, String downloadsDir) {
    final moved = <OrganizeMove>[];
    final errors = <String>[];
    for (final item in plan) {
      try {
        final file = File(item.old);
        if (!file.existsSync()) {
          errors.add('${item.name}: gone before I could move it.');
          continue;
        }
        final destDir = item.newPath.substring(
            0, item.newPath.lastIndexOf(_sep));
        Directory(destDir).createSync(recursive: true);
        // Re-check the free path at move time (never overwrite).
        final dest = freePath(destDir, item.newPath.split(_sep).last);
        file.renameSync(dest);
        moved.add(item.copyWith(newPath: dest));
      } catch (err) {
        errors.add('${item.name}: $err');
      }
    }
    final logPath = _joinPath([downloadsDir, organizerLog]);
    if (moved.isNotEmpty) {
      final err = appendOrganizerLog(
        logPath,
        moved
            .map((m) => [m.name, m.old, m.newPath, todayIso()])
            .toList(),
      );
      if (err != null) errors.add(err);
    }
    return (moved: moved, errors: errors, logPath: logPath);
  }
}
