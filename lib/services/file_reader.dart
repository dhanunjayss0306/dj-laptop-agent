// File reader. Port of src/main/services/fileReader.ts.
// Reads the text out of a file and says HONESTLY what it found.
// Never writes into a file. 20 MB file cap; unreadable files are
// skipped, not silently emptied.
//
// Pure Dart, no new dependencies: DOCX/PPTX/XLSX are read with a
// minimal ZIP reader (stored + deflate entries) + XML pulls, the
// same technique as the JS code. PDF text is extracted best-effort
// from content streams (FlateDecode via ZLibDecoder); a PDF with
// pages but zero extractable text is 'no-text' (scanned image),
// a locked PDF is 'encrypted'. Old binary Office .doc/.xls/.ppt
// are NOT supported — say so, do not pretend.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

typedef ReadStatus = String; // 'ok' | 'no-text' | 'encrypted' | 'unreadable'

class FileContent {
  final String text;
  final String status;
  final int? pages;
  const FileContent({required this.text, required this.status, this.pages});
}

/// Most text DJ keeps from one PDF.
const int pdfTextLimit = 200000;

/// Files bigger than this are skipped.
const int maxFileMb = 20;

const Set<String> readableExts = {
  '.txt', '.md', '.py', '.js', '.ts', '.jsx', '.tsx', '.html', '.css',
  '.json', '.csv', '.log', '.pdf', '.docx', '.pptx', '.xlsx',
};

String _decodeXmlEntities(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

bool isProbablyBinary(String filePath) {
  try {
    final raf = File(filePath).openSync(mode: FileMode.read);
    try {
      final buf = Uint8List(512);
      final read = raf.readIntoSync(buf);
      for (var i = 0; i < read; i++) {
        if (buf[i] == 0) return true;
      }
      return false;
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return false;
  }
}

// --- minimal ZIP reader (stored + deflate) -------------------------------

/// Returns {entryName: bytes} for a ZIP archive, or null if it is
/// not a readable ZIP.
Map<String, Uint8List>? _readZip(Uint8List bytes) {
  // Find End Of Central Directory.
  var eocd = -1;
  for (var i = bytes.length - 22; i >= 0; i--) {
    if (bytes[i] == 0x50 && bytes[i + 1] == 0x4B && bytes[i + 2] == 0x05 && bytes[i + 3] == 0x06) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) return null;
  final total = bytes[eocd + 10] | (bytes[eocd + 11] << 8);
  var cdOff = bytes[eocd + 16] |
      (bytes[eocd + 17] << 8) |
      (bytes[eocd + 18] << 16) |
      (bytes[eocd + 19] << 24);
  final out = <String, Uint8List>{};
  for (var n = 0; n < total; n++) {
    if (cdOff + 46 > bytes.length) return null;
    if (!(bytes[cdOff] == 0x50 && bytes[cdOff + 1] == 0x4B && bytes[cdOff + 2] == 0x01 && bytes[cdOff + 3] == 0x02)) {
      return null;
    }
    final method = bytes[cdOff + 10] | (bytes[cdOff + 11] << 8);
    final compSize = bytes[cdOff + 20] |
        (bytes[cdOff + 21] << 8) |
        (bytes[cdOff + 22] << 16) |
        (bytes[cdOff + 23] << 24);
    final nameLen = bytes[cdOff + 28] | (bytes[cdOff + 29] << 8);
    final extraLen = bytes[cdOff + 30] | (bytes[cdOff + 31] << 8);
    final commentLen = bytes[cdOff + 32] | (bytes[cdOff + 33] << 8);
    final localOff = bytes[cdOff + 42] |
        (bytes[cdOff + 43] << 8) |
        (bytes[cdOff + 44] << 16) |
        (bytes[cdOff + 45] << 24);
    final name = utf8.decode(bytes.sublist(cdOff + 46, cdOff + 46 + nameLen),
        allowMalformed: true);
    // Local header: 30 bytes + name + extra.
    final lhNameLen = bytes[localOff + 26] | (bytes[localOff + 27] << 8);
    final lhExtraLen = bytes[localOff + 28] | (bytes[localOff + 29] << 8);
    final dataOff = localOff + 30 + lhNameLen + lhExtraLen;
    final comp = bytes.sublist(dataOff, dataOff + compSize);
    Uint8List data;
    if (method == 0) {
      data = comp;
    } else if (method == 8) {
      try {
        data = Uint8List.fromList(ZLibDecoder(raw: true).convert(comp));
      } catch (_) {
        return null;
      }
    } else {
      return null; // unsupported compression
    }
    out[name] = data;
    cdOff += 46 + nameLen + extraLen + commentLen;
  }
  return out;
}

FileContent _readDocx(Uint8List bytes) {
  final zip = _readZip(bytes);
  if (zip == null) return const FileContent(text: '', status: 'unreadable');
  final xml = zip['word/document.xml'];
  if (xml == null) return const FileContent(text: '', status: 'no-text');
  final text = utf8.decode(xml, allowMalformed: true);
  final runs = RegExp(r'<w:t[^>]*>([\s\S]*?)</w:t>')
      .allMatches(text)
      .map((m) => _decodeXmlEntities(m.group(1)!))
      .join(' ');
  return runs.trim().isNotEmpty
      ? FileContent(text: runs, status: 'ok')
      : const FileContent(text: '', status: 'no-text');
}

FileContent _readPptx(Uint8List bytes) {
  final zip = _readZip(bytes);
  if (zip == null) return const FileContent(text: '', status: 'unreadable');
  final slideNames = zip.keys
      .where((n) => RegExp(r'^ppt/slides/slide\d+\.xml$').hasMatch(n))
      .toList()
    ..sort((a, b) {
      final na = int.tryParse(RegExp(r'slide(\d+)\.xml$').firstMatch(a)?.group(1) ?? '0') ?? 0;
      final nb = int.tryParse(RegExp(r'slide(\d+)\.xml$').firstMatch(b)?.group(1) ?? '0') ?? 0;
      return na.compareTo(nb);
    });
  final parts = <String>[];
  for (final name in slideNames) {
    final xml = utf8.decode(zip[name]!, allowMalformed: true);
    final t = RegExp(r'<a:t>([\s\S]*?)</a:t>')
        .allMatches(xml)
        .map((m) => _decodeXmlEntities(m.group(1)!))
        .join(' ');
    if (t.trim().isNotEmpty) parts.add(t);
  }
  final text = parts.join('\n');
  return text.trim().isNotEmpty
      ? FileContent(text: text, status: 'ok')
      : const FileContent(text: '', status: 'no-text');
}

FileContent _readXlsx(Uint8List bytes) {
  final zip = _readZip(bytes);
  if (zip == null) return const FileContent(text: '', status: 'unreadable');
  final shared = <String>[];
  final sharedFile = zip['xl/sharedStrings.xml'];
  if (sharedFile != null) {
    final xml = utf8.decode(sharedFile, allowMalformed: true);
    for (final m in RegExp(r'<t[^>]*>([\s\S]*?)</t>').allMatches(xml)) {
      shared.add(_decodeXmlEntities(m.group(1)!));
    }
  }
  final sheetNames = zip.keys
      .where((n) => RegExp(r'^xl/worksheets/sheet\d+\.xml$').hasMatch(n))
      .toList()
    ..sort();
  final rows = <String>[];
  for (final name in sheetNames) {
    final xml = utf8.decode(zip[name]!, allowMalformed: true);
    for (final rowMatch in RegExp(r'<row[\s>][\s\S]*?</row>|<row[\s>][\s\S]*?/>')
        .allMatches(xml)) {
      final rowXml = rowMatch.group(0)!;
      final cells = <String>[];
      for (final cellMatch in RegExp(
              r'<c(\s[^>]*)?>([\s\S]*?)</c>|<c(\s[^>]*)?/>')
          .allMatches(rowXml)) {
        final attrs = cellMatch.group(1) ?? cellMatch.group(3) ?? '';
        final inner = cellMatch.group(2) ?? '';
        final type = RegExp(r'\bt="([^"]+)"').firstMatch(attrs)?.group(1) ?? '';
        if (type == 's') {
          final v = RegExp(r'<v>(\d+)</v>').firstMatch(inner);
          if (v != null) {
            final idx = int.tryParse(v.group(1)!) ?? -1;
            if (idx >= 0 && idx < shared.length) cells.add(shared[idx]);
          }
        } else if (type == 'inlineStr') {
          final t = RegExp(r'<t[^>]*>([\s\S]*?)</t>').firstMatch(inner);
          if (t != null) cells.add(_decodeXmlEntities(t.group(1)!));
        } else {
          final v = RegExp(r'<v>([\s\S]*?)</v>').firstMatch(inner);
          if (v != null) cells.add(v.group(1)!);
        }
      }
      if (cells.isNotEmpty) rows.add(cells.join(' '));
    }
  }
  final text = rows.join('\n');
  return text.trim().isNotEmpty
      ? FileContent(text: text, status: 'ok')
      : const FileContent(text: '', status: 'no-text');
}

// --- PDF (best-effort text extraction) ------------------------------------

String _pdfStringLiteral(String s) {
  final out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final c = s[i];
    if (c == '\\' && i + 1 < s.length) {
      final n = s[i + 1];
      if (n == 'n') {
        out.write('\n');
        i += 2;
      } else if (n == 'r') {
        out.write('\r');
        i += 2;
      } else if (n == 't') {
        out.write('\t');
        i += 2;
      } else if (RegExp(r'[0-7]').hasMatch(n)) {
        var oct = '';
        var j = i + 1;
        while (j < s.length && j < i + 4 && RegExp(r'[0-7]').hasMatch(s[j])) {
          oct += s[j];
          j++;
        }
        out.writeCharCode(int.parse(oct, radix: 8));
        i = j;
      } else {
        out.write(n);
        i += 2;
      }
    } else {
      out.write(c);
      i++;
    }
  }
  return out.toString();
}

FileContent _readPdf(Uint8List bytes) {
  final latin = latin1.decode(bytes, allowInvalid: true);
  if (latin.contains('/Encrypt')) {
    return const FileContent(text: '', status: 'encrypted');
  }
  final pages = RegExp(r'/Type\s*/Page[^s]').allMatches(latin).length;
  final buf = StringBuffer();
  // Find stream...endstream blocks; inflate when FlateDecode, else raw.
  final streamRe = RegExp(r'stream\r?\n([\s\S]*?)\r?\nendstream');
  var foundAny = false;
  for (final m in streamRe.allMatches(latin)) {
    foundAny = true;
    final headerStart = latin.lastIndexOf('<<', m.start);
    final header = headerStart >= 0
        ? latin.substring(headerStart, m.start)
        : '';
    final isFlate = header.contains('/FlateDecode');
    List<int> data;
    if (isFlate) {
      try {
        // latin1 round-trip recovers the raw bytes of the stream.
        final raw = latin1.encode(m.group(1)!);
        data = ZLibDecoder(raw: true).convert(raw);
      } catch (_) {
        continue;
      }
    } else {
      data = latin1.encode(m.group(1)!);
    }
    final text = latin1.decode(data, allowInvalid: true);
    // (literal) Tj and [...] TJ text-showing operators.
    for (final tj in RegExp(r'\((?:[^()\\]|\\.)*\)\s*Tj').allMatches(text)) {
      final lit = RegExp(r'\((?:[^()\\]|\\.)*\)').firstMatch(tj.group(0)!)!.group(0)!;
      buf.write(_pdfStringLiteral(lit.substring(1, lit.length - 1)));
      buf.write(' ');
    }
    for (final tj in RegExp(r'\[((?:[^\[\]\\]|\\.)*)\]\s*TJ').allMatches(text)) {
      final inner = tj.group(1)!;
      for (final lit in RegExp(r'\((?:[^()\\]|\\.)*\)').allMatches(inner)) {
        final s = lit.group(0)!;
        buf.write(_pdfStringLiteral(s.substring(1, s.length - 1)));
      }
      buf.write(' ');
    }
    buf.write('\f');
  }
  if (!foundAny) return const FileContent(text: '', status: 'unreadable');
  final text = buf.toString();
  if (text.trim().isEmpty) {
    return FileContent(text: '', status: 'no-text', pages: pages > 0 ? pages : null);
  }
  return FileContent(
      text: text.length > pdfTextLimit ? text.substring(0, pdfTextLimit) : text,
      status: 'ok',
      pages: pages > 0 ? pages : null);
}

/// Read the text out of a file, with an honest status.
Future<FileContent> readFileContent(String filePath) async {
  final ext = _ext(filePath);
  try {
    final file = File(filePath);
    if (!file.existsSync()) {
      return const FileContent(text: '', status: 'unreadable');
    }
    if (file.lengthSync() > maxFileMb * 1024 * 1024) {
      return const FileContent(text: '', status: 'unreadable');
    }
    if (ext == '.pdf') return _readPdf(file.readAsBytesSync());
    if (ext == '.docx') return _readDocx(file.readAsBytesSync());
    if (ext == '.pptx') return _readPptx(file.readAsBytesSync());
    if (ext == '.xlsx') return _readXlsx(file.readAsBytesSync());
    if (ext == '.doc' || ext == '.ppt' || ext == '.xls') {
      // Old binary Office — NOT supported. Say so plainly.
      return const FileContent(text: '', status: 'unreadable');
    }
    if (isProbablyBinary(filePath)) {
      return const FileContent(text: '', status: 'unreadable');
    }
    try {
      return FileContent(text: file.readAsStringSync(encoding: utf8), status: 'ok');
    } catch (_) {
      return FileContent(text: file.readAsStringSync(encoding: latin1), status: 'ok');
    }
  } catch (_) {
    return const FileContent(text: '', status: 'unreadable');
  }
}

/// Read the text out of a file, capped at [maxChars] (default 8,000).
/// Kept for callers that only need the text (summaries).
Future<String> readText(String filePath, [int maxChars = 8000]) async {
  final content = await readFileContent(filePath);
  final text = content.text;
  return text.length > maxChars ? text.substring(0, maxChars) : text;
}

String _ext(String path) {
  final name = path.split(Platform.pathSeparator).last;
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot).toLowerCase();
}
