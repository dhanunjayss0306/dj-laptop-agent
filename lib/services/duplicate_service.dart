// Duplicates service. Port of src/main/services/duplicateService.ts.
// Find extra copies (size first, then SHA-256), delete the ones the
// user picks (to the Recycle Bin ONLY, via SystemOps — never
// File.delete()), and merge a group (keep the first copy in place,
// move the rest into one folder the user picks).
//
// JUDGE WIRING (fixes the Electron bug): delete/merge are gated by
// judgeAction() here AND in ChatService — a destructive action with
// 0 targets is blocked and nothing runs. The UI must still confirm
// first; the keeper (first copy) is never offered for deletion.
import 'dart:io';

import '../core/hashing.dart';
import '../core/judge.dart';
import '../core/models.dart';
import '../core/security.dart';
import 'organize_log.dart';
import 'organize_service.dart';
import 'system_ops.dart';

const int maxDupMb = 500;
const Set<String> skipDirs = {
  'appdata', '.git', 'node_modules', '__pycache__', '.venv', 'venv',
  '.cache', '.antigravity', '.dart_tool', '.pub-cache', '.gradle',
  'dj_data', '\$recycle.bin', 'system volume information',
  'onedrivetemp', 'programdata', 'windows',
};

class DuplicateService {
  final SystemOps? systemOps;
  DuplicateService({this.systemOps});

  // Files processed since the last yield to the event loop. The scan
  // below is synchronous filesystem work (listSync/statSync) plus
  // pure-Dart SHA-256; without a periodic yield the UI isolate cannot
  // schedule a frame for the whole scan, so the window sits blank
  // white until it finishes. Yielding every few hundred files (and
  // after each hashed file, the expensive step) keeps the UI alive.
  int _sinceYield = 0;

  Future<void> _yieldToEventLoop() async {
    _sinceYield = 0;
    // Duration.zero yields to the event loop (not just the microtask
    // queue), so a pending frame gets its turn.
    await Future<void>.delayed(Duration.zero);
  }

  /// Find extra copies in the given folders. Biggest waste first.
  Future<List<DuplicateGroup>> find(List<String> folders) async {
    _sinceYield = 0;
    final bySize = <int, List<String>>{};
    for (final folder in folders) {
      if (!_isDirectory(folder)) continue;
      await _walk(folder, (filePath, size) {
        if (size <= 0 || size > maxDupMb * 1024 * 1024) return;
        (bySize[size] ??= []).add(filePath);
      });
    }
    final groups = <DuplicateGroup>[];
    for (final entry in bySize.entries) {
      final size = entry.key;
      final paths = entry.value;
      if (paths.length < 2) continue;

      // Two-stage hashing: for larger files, compute a 16 KB head+tail
      // quick signature in a background isolate first so non-matching files
      // never incur a full-file read.
      var candidates = paths;
      if (size > 16384) {
        final byQuick = <String, List<String>>{};
        for (final p in candidates) {
          final sig = await quickFileSignatureAsync(p);
          if (sig == null) continue;
          (byQuick[sig] ??= []).add(p);
        }
        candidates = [
          for (final bucket in byQuick.values)
            if (bucket.length >= 2) ...bucket,
        ];
        if (candidates.length < 2) continue;
      }

      final byHash = <String, List<String>>{};
      for (final p in candidates) {
        final digest = await sha256FileAsync(p);
        if (digest == null) continue;
        (byHash[digest] ??= []).add(p);
        await _yieldToEventLoop();
      }
      for (final dupPaths in byHash.values) {
        if (dupPaths.length < 2) continue;
        final sorted = [...dupPaths]
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        final files = <DuplicateFile>[];
        for (final p in sorted) {
          var mtime = '';
          try {
            final st = await File(p).stat();
            mtime = st.modified.toIso8601String().substring(0, 10);
          } catch (_) {}
          files.add(DuplicateFile(
            path: p,
            name: p.split(Platform.pathSeparator).last,
            folder: p.substring(0, p.lastIndexOf(Platform.pathSeparator)),
            mtime: mtime,
          ));
        }
        groups.add(DuplicateGroup(
          id: '$size-${files[0].path}',
          size: size,
          sizeText: humanSize(size),
          wasted: size * (files.length - 1),
          files: files,
        ));
      }
    }
    groups.sort((a, b) => b.wasted.compareTo(a.wasted));
    return groups;
  }

  Future<void> _walk(String dir, void Function(String, int) onFile) async {
    final stream = Directory(dir).list(followLinks: false);
    var visited = 0;
    try {
      await for (final entry in stream) {
        if (entry is Link) continue;
        final name = entry.path.split(Platform.pathSeparator).last;
        if (entry is Directory) {
          if (skipDirs.contains(name.toLowerCase())) continue;
          if (name.startsWith('.') || isSensitivePath(entry.path)) continue;
          await _walk(entry.path, onFile);
        } else if (entry is File) {
          if (name.startsWith('.') || isSensitivePath(entry.path)) continue;
          if (organizerSkip.contains(name.toLowerCase())) continue;
          try {
            final st = await entry.stat();
            if (st.type == FileSystemEntityType.link) continue;
            onFile(entry.path, st.size);
          } catch (_) {
            continue;
          }
          if (++_sinceYield >= 128) await _yieldToEventLoop();
        }
        visited += 1;
        if (visited % 40 == 0) {
          await _yieldToEventLoop();
        }
      }
    } catch (_) {
      return;
    }
  }

  /// Send files to the Recycle Bin (never permanent delete).
  /// Judged first: with no clear target the delete is blocked.
  /// [trashFn] is injected for tests (defaults to SystemOps).
  Future<({List<String> deleted, List<String> errors, String logPath})>
      deleteToRecycleBin(String logDir, List<String> paths,
          {Future<void> Function(List<String>)? trashFn}) async {
    final logPath =
        '$logDir${Platform.pathSeparator}$organizerLog';
    final judged = judgeAction(JudgeInput(
      kind: 'delete',
      text: 'delete the extra copies',
      destructive: true,
      targetCount: paths.length,
    ));
    if (judged.blocked.isNotEmpty) {
      return (deleted: <String>[], errors: judged.blocked, logPath: logPath);
    }
    final deleted = <String>[];
    final errors = <String>[];
    final rows = <List<String>>[];
    final trash = trashFn ??
        (systemOps == null
            ? null
            : (List<String> ps) => systemOps!.deleteToTrash(ps));
    if (trash == null) {
      return (
        deleted: deleted,
        errors: [
          'No Recycle Bin handler is available yet — the platform plugin must implement deleteToTrash before deletes can run safely.'
        ],
        logPath: logPath,
      );
    }
    final existing = <String>[];
    for (final p in paths) {
      final file = File(p);
      if (!file.existsSync()) {
        errors.add('${p.split(Platform.pathSeparator).last}: already gone.');
        continue;
      }
      existing.add(p);
    }
    if (existing.isNotEmpty) {
      try {
        await trash(existing);
        for (final p in existing) {
          deleted.add(p);
          rows.add([
            p.split(Platform.pathSeparator).last,
            p,
            'Recycle Bin (deleted)',
            todayIso(),
          ]);
        }
      } catch (err) {
        errors.add('Could not move files to the Recycle Bin: $err');
      }
    }
    if (rows.isNotEmpty) {
      final err = appendOrganizerLog(logPath, rows);
      if (err != null) errors.add(err);
    }
    return (deleted: deleted, errors: errors, logPath: logPath);
  }

  /// Merge a duplicate group: keep the first copy where it is, move
  /// the other copies into [targetFolder]. Judged first.
  ({List<String> moved, List<String> errors}) merge(
      List<String> paths, String targetFolder) {
    final judged = judgeAction(JudgeInput(
      kind: 'merge',
      text: 'merge the extra copies into $targetFolder',
      destructive: true,
      targetCount: paths.length,
    ));
    if (judged.blocked.isNotEmpty) {
      return (moved: <String>[], errors: judged.blocked);
    }
    final moved = <String>[];
    final errors = <String>[];
    if (paths.length < 2) {
      errors.add('Nothing to merge — a group needs at least two copies.');
      return (moved: moved, errors: errors);
    }
    Directory(targetFolder).createSync(recursive: true);
    // paths[0] is the copy that stays; the rest move.
    for (final p in paths.sublist(1)) {
      try {
        final file = File(p);
        if (!file.existsSync()) {
          errors.add(
              '${p.split(Platform.pathSeparator).last}: gone before I could move it.');
          continue;
        }
        final dest = freePath(
            targetFolder, p.split(Platform.pathSeparator).last);
        file.renameSync(dest);
        moved.add(dest);
      } catch (err) {
        errors.add('${p.split(Platform.pathSeparator).last}: $err');
      }
    }
    return (moved: moved, errors: errors);
  }
}

bool _isDirectory(String p) {
  try {
    return Directory(p).statSync().type == FileSystemEntityType.directory;
  } catch (_) {
    return false;
  }
}
