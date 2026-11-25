// File-type icons and formatting, per PORTING-SPEC.md section 1.5.
// Kinds: word, pdf, image, video, audio, folder, sheet, archive, code,
// text, file. formatBytes: <1024 -> "N B", else 1 decimal KB/MB,
// 2 decimals GB. formatDate: ISO -> "12 Nov 2026", empty/invalid -> "".
import 'package:flutter/material.dart';

enum FileKind {
  word,
  pdf,
  image,
  video,
  audio,
  folder,
  sheet,
  archive,
  code,
  text,
  file,
}

const Map<String, FileKind> _extKinds = {
  '.doc': FileKind.word,
  '.docx': FileKind.word,
  '.pdf': FileKind.pdf,
  '.png': FileKind.image,
  '.jpg': FileKind.image,
  '.jpeg': FileKind.image,
  '.gif': FileKind.image,
  '.webp': FileKind.image,
  '.bmp': FileKind.image,
  '.svg': FileKind.image,
  '.ico': FileKind.image,
  '.mp4': FileKind.video,
  '.mov': FileKind.video,
  '.avi': FileKind.video,
  '.mkv': FileKind.video,
  '.webm': FileKind.video,
  '.wmv': FileKind.video,
  '.mp3': FileKind.audio,
  '.wav': FileKind.audio,
  '.ogg': FileKind.audio,
  '.flac': FileKind.audio,
  '.m4a': FileKind.audio,
  '.xls': FileKind.sheet,
  '.xlsx': FileKind.sheet,
  '.ods': FileKind.sheet,
  '.zip': FileKind.archive,
  '.rar': FileKind.archive,
  '.7z': FileKind.archive,
  '.tar': FileKind.archive,
  '.gz': FileKind.archive,
  '.js': FileKind.code,
  '.ts': FileKind.code,
  '.jsx': FileKind.code,
  '.tsx': FileKind.code,
  '.py': FileKind.code,
  '.java': FileKind.code,
  '.c': FileKind.code,
  '.cpp': FileKind.code,
  '.h': FileKind.code,
  '.html': FileKind.code,
  '.css': FileKind.code,
  '.json': FileKind.code,
  '.xml': FileKind.code,
  '.sql': FileKind.code,
  '.sh': FileKind.code,
  '.txt': FileKind.text,
  '.md': FileKind.text,
  '.csv': FileKind.text,
  '.log': FileKind.text,
  '.rtf': FileKind.text,
};

FileKind fileKindForPath(String path, {bool isFolder = false}) {
  if (isFolder) return FileKind.folder;
  final name = path.split('/').last.split(r'\').last;
  final dot = name.lastIndexOf('.');
  if (dot < 0) return FileKind.file;
  final ext = name.substring(dot).toLowerCase();
  return _extKinds[ext] ?? FileKind.file;
}

IconData fileKindIcon(FileKind kind) {
  return switch (kind) {
    FileKind.word => Icons.description,
    FileKind.pdf => Icons.picture_as_pdf,
    FileKind.image => Icons.image,
    FileKind.video => Icons.movie,
    FileKind.audio => Icons.audiotrack,
    FileKind.folder => Icons.folder,
    FileKind.sheet => Icons.table_chart,
    FileKind.archive => Icons.archive,
    FileKind.code => Icons.code,
    FileKind.text => Icons.article,
    FileKind.file => Icons.insert_drive_file,
  };
}

/// <1024 -> "N B", else 1 decimal KB/MB, 2 decimals GB. Null -> "".
String formatBytes(int? bytes) {
  if (bytes == null) return '';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

const List<String> _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// ISO date -> "12 Nov 2026". Empty or invalid -> "".
String formatDate(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return '';
  final day = parsed.day.toString().padLeft(2, '0');
  return '$day ${_months[parsed.month - 1]} ${parsed.year}';
}
