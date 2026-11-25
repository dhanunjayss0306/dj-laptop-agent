// Index service. Port of src/main/services/indexService.ts +
// vectorStore.ts + the two repositories.
//
// Two parts: (1) keyword search (always available) over file names
// + first 12,000 chars of text; (2) meaning search over 768-dim
// vectors, via the Embedder interface below.
//
// THE EMBEDDER IS A FUTURE STEP: the nomic-embed-text-v1.5 model
// (131 MB ONNX) is NOT bundled here and no ONNX runs in this task.
// The default embedder is NotStartedEmbedder ('not-started' /
// 'unavailable'), so keyword search works fully without any model
// and the stored vectors (format 2, 768-dim, prefix-trained) from
// the Electron app stay loadable. A real embedder plugs in later
// behind this interface — it must reproduce 768-dim, mean pooling,
// L2 normalization, q8 model, and the 'search_document: ' /
// 'search_query: ' prefixes.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../core/hashing.dart';
import '../core/models.dart';
import '../core/text_utils.dart';
import 'file_reader.dart';

export '../core/models.dart' show IndexCounts, IndexProgress, SearchResult;

const Set<String> readableExtsIndex = {
  '.txt', '.md', '.py', '.js', '.ts', '.jsx', '.tsx', '.html', '.css',
  '.json', '.csv', '.log', '.pdf', '.docx', '.pptx', '.xlsx',
};

const Set<String> skipDirsIndex = {
  'appdata', '.git', 'node_modules', '__pycache__', '.venv', 'venv',
  '.cache', '.antigravity', 'dj_data', '\$recycle.bin',
  'system volume information',
};

const int maxFileMbIndex = 20;
const int keywordTextLimit = 12000;
const int embedBatch = 5;
const int embedDim = 768;
const int embedFormatVersion = 2;
const String embedModelId = 'Xenova/nomic-embed-text-v1.5';
const String docPrefix = 'search_document: ';
const String queryPrefix = 'search_query: ';
const int progressMinMs = 150;
const int readTimeoutMs = 15000;
const int skippedNamesMax = 20;

const String meaningLoadingNote =
    'Meaning search is still loading — these are keyword matches for now.';
const String meaningUnavailableNote =
    'Meaning search is unavailable right now — these are keyword matches.';

typedef MeaningStatus = String; // 'ready' | 'loading' | 'unavailable' | 'not-indexed'
typedef ProgressCallback = void Function(IndexProgress p);

/// The embedding model, behind an interface. The shipped state is
/// 'not-started' until a real embedder is plugged in.
abstract class Embedder {
  String get state; // EmbedderState
  String get source; // EmbedderSource
  bool get isReady;
  Future<List<List<double>>?> embedTexts(List<String> texts, bool forQuery);
  Future<List<double>?> embedQuery(String query);
}

/// No model yet: every embed returns null and the state is
/// 'unavailable' after the first attempt (keyword search only).
class NotStartedEmbedder implements Embedder {
  String _state = 'not-started';
  @override
  String get state => _state;
  @override
  String get source => 'none';
  @override
  bool get isReady => _state == 'ready';

  @override
  Future<List<List<double>>?> embedTexts(
      List<String> texts, bool forQuery) async {
    if (_state == 'not-started') _state = 'loading';
    _state = 'unavailable';
    return null;
  }

  @override
  Future<List<double>?> embedQuery(String query) async {
    await embedTexts([query], true);
    return null;
  }
}

/// One stored vector row (in-memory; persisted as vectors.bin +
/// vectors_meta.json, same order).
class StoredVector {
  final String id;
  final String path;
  final String name;
  final String folder;
  final int chunk;
  final String text;
  final Float32List vector;
  StoredVector({
    required this.id,
    required this.path,
    required this.name,
    required this.folder,
    required this.chunk,
    required this.text,
    required this.vector,
  });
  VectorMeta get meta => VectorMeta(
      id: id, path: path, name: name, folder: folder, chunk: chunk, text: text);
}

/// In-memory brute-force cosine search (vectors L2-normalized on
/// store, so cosine = dot product). No server, no native module.
class VectorStore {
  final List<StoredVector> _rows = [];
  int embedFormat = embedFormatVersion;
  int? chunkVersion;

  List<StoredVector> get rows => List.unmodifiable(_rows);
  bool get hasStoredVectors => _rows.isNotEmpty;

  void replace(List<StoredVector> rows, String model) {
    _rows
      ..clear()
      ..addAll(rows.map(_normalizeRow));
    embedFormat = embedFormatVersion;
    chunkVersion = chunkVersionValue;
  }

  void clear() {
    _rows.clear();
    embedFormat = embedFormatVersion;
    chunkVersion = chunkVersionValue;
  }

  StoredVector _normalizeRow(StoredVector row) {
    var norm = 0.0;
    for (final v in row.vector) {
      norm += v * v;
    }
    norm = math.sqrt(norm);
    if (norm == 0) return row;
    final vec = Float32List(row.vector.length);
    for (var i = 0; i < row.vector.length; i++) {
      vec[i] = row.vector[i] / norm;
    }
    return StoredVector(
      id: row.id,
      path: row.path,
      name: row.name,
      folder: row.folder,
      chunk: row.chunk,
      text: row.text,
      vector: vec,
    );
  }

  /// Cosine search. Zero query vector -> no matches. Scores rounded
  /// to 3 decimals.
  List<({StoredVector row, double score})> search(
      List<double> query, int topN) {
    var norm = 0.0;
    for (final v in query) {
      norm += v * v;
    }
    if (norm == 0) return [];
    norm = math.sqrt(norm);
    final scored = <({StoredVector row, double score})>[];
    for (final row in _rows) {
      final n = math.min(query.length, row.vector.length);
      var dot = 0.0;
      for (var i = 0; i < n; i++) {
        dot += (query[i] / norm) * row.vector[i];
      }
      scored.add((row: row, score: (dot * 1000).round() / 1000));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(topN).toList();
  }

  // -- persistence (vectors.bin + vectors_meta.json + index_meta.json) --

  bool loadFromDisk(String dataDir) {
    try {
      final metaFile = File('$dataDir${Platform.pathSeparator}vectors_meta.json');
      final binFile = File('$dataDir${Platform.pathSeparator}vectors.bin');
      if (!metaFile.existsSync() || !binFile.existsSync()) return false;
      final meta = jsonDecode(metaFile.readAsStringSync());
      if (meta is! Map<String, dynamic>) return false;
      final dim = meta['dim'];
      if (dim != embedDim) return false;
      final vectors = meta['vectors'] as List? ?? [];
      final bytes = binFile.readAsBytesSync();
      if (bytes.lengthInBytes != vectors.length * embedDim * 4) return false;
      embedFormat = meta['embedFormat'] is num
          ? (meta['embedFormat'] as num).toInt()
          : embedFormatVersion;
      chunkVersion = meta['chunkVersion'] is num
          ? (meta['chunkVersion'] as num).toInt()
          : null;
      final floats = Float32List.view(bytes.buffer, 0, vectors.length * embedDim);
      _rows.clear();
      for (var i = 0; i < vectors.length; i++) {
        final m = vectors[i];
        if (m is! Map<String, dynamic>) continue;
        final vec = Float32List(embedDim);
        for (var d = 0; d < embedDim; d++) {
          vec[d] = floats[i * embedDim + d];
        }
        _rows.add(StoredVector(
          id: m['id'] as String? ?? '',
          path: m['path'] as String? ?? '',
          name: m['name'] as String? ?? '',
          folder: m['folder'] as String? ?? '',
          chunk: m['chunk'] is num ? (m['chunk'] as num).toInt() : 0,
          text: m['text'] as String? ?? '',
          vector: vec,
        ));
      }
      return _rows.isNotEmpty;
    } catch (_) {
      _rows.clear();
      return false;
    }
  }

  void saveToDisk(String dataDir) {
    final sep = Platform.pathSeparator;
    final meta = {
      'embedFormat': embedFormat,
      'embedModel': embedModelId,
      'dim': embedDim,
      'chunkVersion': chunkVersionValue,
      'vectors': _rows.map((r) => r.meta.toJson()).toList(),
    };
    File('$dataDir${sep}vectors_meta.json')
        .writeAsStringSync(prettyJson(meta));
    File('$dataDir${sep}index_meta.json').writeAsStringSync(prettyJson({
      'embedFormat': embedFormat,
      'embedModel': embedModelId,
      'chunkVersion': chunkVersionValue,
    }));
    final floats = Float32List(_rows.length * embedDim);
    for (var i = 0; i < _rows.length; i++) {
      for (var d = 0; d < embedDim; d++) {
        floats[i * embedDim + d] = _rows[i].vector[d];
      }
    }
    File('$dataDir${sep}vectors.bin')
        .writeAsBytesSync(floats.buffer.asUint8List());
  }
}

const int chunkVersionValue = chunkVersion;

class WalkEntry {
  final String path;
  final int size;
  final double mtimeMs;
  const WalkEntry({required this.path, required this.size, required this.mtimeMs});
}

String noTextNote(String filePath, String status) {
  final name = filePath.split(Platform.pathSeparator).last;
  if (status == 'no-text') {
    return '$name has no readable text inside — scanned image, needs OCR.';
  }
  if (status == 'encrypted') {
    return '$name is locked (encrypted) — open it with its password first.';
  }
  return '';
}

class IndexService {
  final String dataDir;
  final Embedder embedder;
  final ProgressCallback? onProgress;

  List<IndexedFile> _keywordFiles = [];
  List<IndexedFolder> _keywordFolders = [];
  final VectorStore store = VectorStore();

  bool vectorOk = false;
  String lastMeaning = 'not-indexed';
  int _lastProgressAt = 0;

  IndexService({
    required this.dataDir,
    required this.embedder,
    this.onProgress,
  });

  // -- lifecycle ------------------------------------------------------

  void loadFromDisk() {
    final sep = Platform.pathSeparator;
    try {
      final file = File('$dataDir${sep}keyword_index.json');
      if (file.existsSync()) {
        final data = jsonDecode(file.readAsStringSync());
        if (data is Map<String, dynamic>) {
          _keywordFiles = (data['files'] as List? ?? [])
              .whereType<Map<String, dynamic>>()
              .map(IndexedFile.fromJson)
              .toList();
          _keywordFolders = (data['folders'] as List? ?? [])
              .whereType<Map<String, dynamic>>()
              .map(IndexedFolder.fromJson)
              .toList();
        }
      }
    } catch (_) {
      _keywordFiles = [];
      _keywordFolders = [];
    }
    vectorOk = store.loadFromDisk(dataDir);
  }

  bool hasIndex() => _keywordFiles.isNotEmpty || store.hasStoredVectors;

  bool indexIsStale() {
    if (!store.hasStoredVectors) return false;
    return store.embedFormat != embedFormatVersion;
  }

  ({int filesIndexed, int foldersIndexed, bool vectorOk}) status() => (
        filesIndexed: _keywordFiles.length,
        foldersIndexed: _keywordFolders.length,
        vectorOk: vectorOk,
      );

  List<IndexedFolder> listFolders() {
    final out = [..._keywordFolders]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  List<IndexedFolder> findFolders(String query) =>
      rankFolders(_keywordFolders, query);

  void _progress(String stage, int done, int total, String message) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (stage != 'done' && now - _lastProgressAt < progressMinMs) return;
    _lastProgressAt = now;
    try {
      onProgress?.call(IndexProgress(
          stage: stage, done: done, total: total, message: message));
    } catch (_) {}
  }

  // -- walking ----------------------------------------------------------

  Future<List<WalkEntry>> iterFileEntries(List<String> folders) async {
    final found = <WalkEntry>[];
    final seen = <String>{};
    for (final folder in folders) {
      if (!_isDirectory(folder)) continue;
      final display = folder.split(Platform.pathSeparator).last;
      final foundBefore = found.length;
      _progress('scan', found.length, 0, 'Scanning $display...');
      try {
        await _walkDir(folder, (filePath, size, mtimeMs) {
          found.add(WalkEntry(path: filePath, size: size, mtimeMs: mtimeMs));
          if (found.length % 200 == 0) {
            _progress('scan', found.length, 0,
                'Scanning $display... ${found.length} files found');
          }
        }, seen);
      } catch (_) {
        continue;
      }
      _progress('scan', found.length, 0, 'Scanned $display: ${found.length - foundBefore} files found');
    }
    return found;
  }

  Future<List<String>> iterFiles(List<String> folders) async =>
      (await iterFileEntries(folders)).map((e) => e.path).toList();

  Future<void> _walkDir(
    String dir,
    void Function(String, int, double) onFile,
    Set<String> seen, [
    void Function(String)? onDir,
  ]) async {
    List<FileSystemEntity> entries;
    try {
      entries = Directory(dir).listSync();
    } catch (_) {
      return;
    }
    var visited = 0;
    for (final entry in entries) {
      final name = entry.path.split(Platform.pathSeparator).last;
      if (entry is Directory) {
        if (skipDirsIndex.contains(name.toLowerCase())) continue;
        if (name.startsWith('.')) continue;
        if (entry is Link) continue;
        onDir?.call(entry.path);
        await _walkDir(entry.path, onFile, seen, onDir);
      } else if (entry is File) {
        if (name.startsWith('.')) continue;
        final ext = _ext(name);
        if (!readableExtsIndex.contains(ext)) continue;
        int size;
        double mtimeMs;
        try {
          final st = entry.statSync();
          size = st.size;
          mtimeMs = st.modified.millisecondsSinceEpoch.toDouble();
        } catch (_) {
          continue;
        }
        if (size > maxFileMbIndex * 1024 * 1024) continue;
        String key;
        try {
          key = entry.resolveSymbolicLinksSync();
        } catch (_) {
          key = entry.path;
        }
        if (seen.contains(key)) continue;
        seen.add(key);
        onFile(entry.path, size, mtimeMs);
      }
      visited += 1;
      if (visited % 200 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
  }

  Future<List<IndexedFolder>> iterFolders(List<String> folders) async {
    final found = <IndexedFolder>[];
    final seen = <String>{};
    void record(String dirPath) {
      String key;
      try {
        key = Directory(dirPath).resolveSymbolicLinksSync();
      } catch (_) {
        key = dirPath;
      }
      if (seen.contains(key)) return;
      seen.add(key);
      final sep = Platform.pathSeparator;
      found.add(IndexedFolder(
        path: dirPath,
        name: dirPath.split(sep).last.isEmpty ? dirPath : dirPath.split(sep).last,
        parent: dirPath.contains(sep)
            ? dirPath.substring(0, dirPath.lastIndexOf(sep))
            : '',
      ));
    }

    for (final folder in folders) {
      if (!_isDirectory(folder)) continue;
      record(folder);
      try {
        await _walkDir(folder, (_, __, ___) {}, <String>{}, record);
      } catch (_) {
        continue;
      }
    }
    return found;
  }

  // -- build ------------------------------------------------------------

  Future<IndexCounts> build(List<String> folders) async {
    final t0 = DateTime.now();
    _lastProgressAt = 0;
    var files = 0;
    var chunks = 0;
    var embedded = 0;
    var keywordOnly = 0;
    var skipped = 0;
    var errors = 0;
    var reused = 0;
    var newCount = 0;
    var removed = 0;
    final skippedNames = <String>[];

    _progress('scan', 0, 1, 'Looking through your folders...');
    final entries = await iterFileEntries(folders);
    final total = entries.isEmpty ? 1 : entries.length;

    final savedByPath = {for (final f in _keywordFiles) f.path: f};
    final entryByPath = {for (final e in entries) e.path: e};
    for (final p in savedByPath.keys) {
      if (!entryByPath.containsKey(p)) removed += 1;
    }
    final storedRowsByPath = <String, List<StoredVector>>{};
    for (final row in store.rows) {
      (storedRowsByPath[row.path] ??= []).add(row);
    }
    // Chunking changed for PDFs in v5.5 (page-aware). An old store
    // has no chunk version, so its PDF rows are re-embedded once.
    final chunkOk = store.chunkVersion == chunkVersionValue;

    final keywordFiles = <IndexedFile>[];
    final reusedRows = <StoredVector>[];
    final toRead = <WalkEntry>[];
    for (final e in entries) {
      final saved = savedByPath[e.path];
      final ext = _ext(e.path);
      final unchanged = saved != null &&
          saved.size == e.size &&
          saved.mtimeMs == e.mtimeMs;
      final needsRechunk = !chunkOk && ext == '.pdf';
      if (unchanged && !needsRechunk) {
        keywordFiles.add(saved);
        reused += 1;
        final rows = storedRowsByPath[e.path];
        if (rows != null) reusedRows.addAll(rows);
      } else {
        toRead.add(e);
      }
    }

    // Phase 1: read the changed files.
    final newChunks = <StoredVector>[];
    final readBase = keywordFiles.length;
    for (var i = 0; i < toRead.length; i++) {
      final entry = toRead[i];
      final sep = Platform.pathSeparator;
      final name = entry.path.split(sep).last;
      final folder = entry.path.substring(0, entry.path.lastIndexOf(sep));
      final ext = _ext(entry.path);
      _progress('read', readBase + i + 1, total, 'Reading $name');
      FileContent content;
      try {
        content = await readFileContent(entry.path)
            .timeout(const Duration(milliseconds: readTimeoutMs));
      } catch (_) {
        errors += 1;
        if (skippedNames.length < skippedNamesMax) skippedNames.add(name);
        continue;
      }
      if (content.status == 'unreadable') {
        errors += 1;
        if (skippedNames.length < skippedNamesMax) skippedNames.add(name);
        continue;
      }
      if (content.status == 'no-text' || content.status == 'encrypted') {
        files += 1;
        newCount += 1;
        keywordFiles.add(IndexedFile(
          path: entry.path,
          name: name,
          folder: folder,
          text: '',
          size: entry.size,
          mtimeMs: entry.mtimeMs,
          note: noTextNote(entry.path, content.status),
        ));
        continue;
      }
      final text = content.text;
      if (text.trim().isEmpty) {
        skipped += 1;
        continue;
      }
      files += 1;
      newCount += 1;
      keywordFiles.add(IndexedFile(
        path: entry.path,
        name: name,
        folder: folder,
        text: text.length > keywordTextLimit
            ? text.substring(0, keywordTextLimit)
            : text,
        size: entry.size,
        mtimeMs: entry.mtimeMs,
      ));
      final chunkTexts = ext == '.pdf' ? chunkPdfText(text) : chunkText(text);
      final fid = fileId(entry.path);
      for (var j = 0; j < chunkTexts.length; j++) {
        newChunks.add(StoredVector(
          id: '$fid-$j',
          path: entry.path,
          name: name,
          folder: folder,
          chunk: j,
          text: chunkTexts[j],
          vector: Float32List(embedDim),
        ));
      }
    }

    // Save the keyword index NOW, before embedding.
    final foldersFound = await iterFolders(folders);
    _keywordFiles = keywordFiles;
    _keywordFolders = foldersFound;
    _saveKeywordIndex();
    files = keywordFiles.length;
    _progress('read', total, total,
        'Keyword search ready: ${keywordFiles.length} files. Embedding ${newChunks.length} new chunks...');

    // Phase 2: embed only the new chunks, in batches of 5.
    final newRows = <StoredVector>[];
    for (var i = 0; i < newChunks.length; i += embedBatch) {
      final batch = newChunks.sublist(
          i, i + embedBatch < newChunks.length ? i + embedBatch : newChunks.length);
      final vecs = await embedder.embedTexts(
          batch.map((c) => c.text).toList(), false);
      if (vecs != null && vecs.length == batch.length) {
        for (var j = 0; j < batch.length; j++) {
          newRows.add(StoredVector(
            id: batch[j].id,
            path: batch[j].path,
            name: batch[j].name,
            folder: batch[j].folder,
            chunk: batch[j].chunk,
            text: batch[j].text,
            vector: Float32List.fromList(vecs[j]),
          ));
        }
      } else {
        keywordOnly += batch.length;
      }
      _progress('read', readBase + toRead.length, total,
          'Embedding new chunks... ${newRows.length + reusedRows.length} with meaning search');
      await Future<void>.delayed(Duration.zero);
    }

    chunks = reusedRows.length + newChunks.length;
    embedded = reusedRows.length + newRows.length;
    final allRows = [...reusedRows, ...newRows];
    if (allRows.isNotEmpty) {
      store.replace(allRows, embedModelId);
      store.saveToDisk(dataDir);
      vectorOk = true;
    } else {
      store.clear();
      store.saveToDisk(dataDir);
      vectorOk = false;
    }

    final seconds =
        (DateTime.now().difference(t0).inMilliseconds / 100).round() / 10;
    _progress('done', total, total,
        'Done: $files files ($newCount new, $reused reused, $removed removed), $chunks chunks in ${seconds}s.');
    return IndexCounts(
      files: files,
      folders: foldersFound.length,
      chunks: chunks,
      embedded: embedded,
      keywordOnly: keywordOnly,
      skipped: skipped,
      errors: errors,
      seconds: seconds,
      vectorOk: vectorOk,
      reused: reused,
      newCount: newCount,
      removed: removed,
      skippedNames: skippedNames,
    );
  }

  void _saveKeywordIndex() {
    final sep = Platform.pathSeparator;
    Directory(dataDir).createSync(recursive: true);
    File('$dataDir${sep}keyword_index.json').writeAsStringSync(prettyJson({
      'version': 1,
      'files': _keywordFiles.map((f) => f.toJson()).toList(),
      'folders': _keywordFolders.map((f) => f.toJson()).toList(),
    }));
  }

  /// The exact summary line posted to chat after a build.
  static String indexBuiltSummary(IndexCounts c) {
    final parts = <String>[
      'Index built: ${c.files} files, ${c.folders} folders, ${c.embedded} with meaning search, ${c.keywordOnly} keyword only',
    ];
    if (c.newCount != null && c.newCount! > 0) parts.add('${c.newCount} new');
    if (c.reused != null && c.reused! > 0) parts.add('${c.reused} reused');
    if (c.removed != null && c.removed! > 0) parts.add('${c.removed} removed');
    if (c.skipped > 0) parts.add('${c.skipped} skipped');
    if (c.errors > 0) parts.add('${c.errors} errors');
    return '${parts.join(', ')}. Took ${c.seconds}s.';
  }

  // -- search -------------------------------------------------------------

  Future<List<SearchResult>> search(String query, [int topN = 8]) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    final kw = keywordSearch(q, topN);
    if (_nameMatches(q, kw)) {
      lastMeaning = 'ready';
      return kw;
    }
    if (vectorOk && embedder.isReady) {
      final vec = await _vectorSearch(q, topN);
      if (vec.isNotEmpty) {
        lastMeaning = 'ready';
        return _mergeResults(vec, kw, topN);
      }
      lastMeaning = 'ready';
      return kw;
    }
    lastMeaning = !vectorOk
        ? 'not-indexed'
        : embedder.state == 'unavailable'
            ? 'unavailable'
            : 'loading';
    final note =
        lastMeaning == 'loading' ? meaningLoadingNote : meaningUnavailableNote;
    return _withMeaningNote(kw, note);
  }

  bool _nameMatches(String query, List<SearchResult> results) {
    final terms = query
        .toLowerCase()
        .split(RegExp(r'\W+'))
        .where((w) => w.length > 2)
        .toList();
    final words = terms.isNotEmpty ? terms : [query.toLowerCase()];
    return results.any(
        (r) => words.any((w) => r.name.toLowerCase().contains(w)));
  }

  List<SearchResult> _mergeResults(
      List<SearchResult> vec, List<SearchResult> kw, int topN) {
    final seen = vec.map((r) => r.path).toSet();
    final out = [...vec];
    for (final r in kw) {
      if (out.length >= topN) break;
      if (seen.contains(r.path)) continue;
      seen.add(r.path);
      out.add(r);
    }
    return out;
  }

  List<SearchResult> _withMeaningNote(
      List<SearchResult> results, String note) {
    return results
        .map((r) => r.copyWith(
            note: r.note != null ? '${r.note} $note' : note))
        .toList();
  }

  Future<List<SearchResult>> _vectorSearch(String query, int topN) async {
    final vec = await embedder.embedQuery(query);
    if (vec == null) return [];
    final hits = store.search(vec, topN * 2);
    final seen = <String, SearchResult>{};
    for (final hit in hits) {
      if (seen.containsKey(hit.row.path)) continue;
      final meta = _statMeta(hit.row.path);
      final cleanText =
          hit.row.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      seen[hit.row.path] = SearchResult(
        path: hit.row.path,
        name: hit.row.name,
        folder: hit.row.folder,
        snippet: cleanText.substring(
            0, cleanText.length < 160 ? cleanText.length : 160),
        score: hit.score,
        size: meta.size,
        mtime: meta.mtime,
      );
      if (seen.length >= topN) break;
    }
    return seen.values.toList();
  }

  /// Plain word search over file names and file text. A word in the
  /// file name scores 10, a word in the text scores 1 per hit
  /// (capped at 20). Best matches first.
  List<SearchResult> keywordSearch(String query, [int topN = 8]) {
    final words = query
        .toLowerCase()
        .split(RegExp(r'\W+'))
        .where((w) => w.length > 2)
        .toList();
    final terms = words.isNotEmpty ? words : [query.toLowerCase()];
    final scored = <({int score, IndexedFile entry})>[];
    for (final entry in _keywordFiles) {
      final name = entry.name.toLowerCase();
      final low = entry.text.toLowerCase();
      var score = 0;
      for (final w in terms) {
        if (name.contains(w)) score += 10;
        final occ = countOccurrences(low, w);
        score += occ < 20 ? occ : 20;
      }
      if (score > 0) scored.add((score: score, entry: entry));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(topN).map((s) {
      final entry = s.entry;
      final meta = _statMeta(entry.path);
      return SearchResult(
        path: entry.path,
        name: entry.name,
        folder: entry.folder,
        snippet: entry.text.isNotEmpty
            ? snippet(entry.text, query)
            : (entry.note ?? ''),
        score: s.score.toDouble(),
        note: entry.note,
        size: meta.size,
        mtime: meta.mtime,
      );
    }).toList();
  }

  /// Read a file's text (for summaries), capped at 8,000 chars.
  Future<String> getFileText(String filePath, [int maxChars = 8000]) =>
      readText(filePath, maxChars);

  /// All indexed files, newest first (for "list recent files").
  List<({String path, String name, String folder, double mtime, int? size})>
      listRecent([int topN = 10]) {
    final rows = <({String path, String name, String folder, double mtime, int? size})>[];
    for (final entry in _keywordFiles) {
      double mtime;
      int? size;
      try {
        final st = File(entry.path).statSync();
        mtime = st.modified.millisecondsSinceEpoch.toDouble();
        size = st.size;
      } catch (_) {
        continue;
      }
      rows.add((
        path: entry.path,
        name: entry.name,
        folder: entry.folder,
        mtime: mtime,
        size: size,
      ));
    }
    rows.sort((a, b) => b.mtime.compareTo(a.mtime));
    return rows.take(topN).toList();
  }

  ({int? size, String? mtime}) _statMeta(String filePath) {
    try {
      final st = File(filePath).statSync();
      return (size: st.size, mtime: st.modified.toIso8601String());
    } catch (_) {
      return (size: null, mtime: null);
    }
  }
}

const Set<String> _folderStopwords = {
  'folder', 'folders', 'directory', 'directories', 'the', 'a', 'an', 'in',
  'open', 'find', 'show', 'go', 'to', 'that', 'this', 'related', 'please',
};

/// Rank folders for a query, best first (at most 8). Scoring:
/// exact name = 100; all words across name+parent = 70; per-word
/// name hit = 25; per-word parent hit = 10 (capped 20); full-path
/// contains phrase = +15; keep only scores within 20 of the best;
/// tie-break shorter path, then name.
List<IndexedFolder> rankFolders(List<IndexedFolder> folders, String query) {
  final words = query
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((w) => w.isNotEmpty && !_folderStopwords.contains(w))
      .toList();
  if (words.isEmpty) return [];
  final phrase = words.join(' ');
  final scored = <({int score, IndexedFolder folder})>[];
  for (final folder in folders) {
    final name = folder.name.toLowerCase();
    final parent = folder.parent.toLowerCase();
    final fullPath = folder.path.toLowerCase();
    var score = 0;
    if (name == phrase) {
      score += 100;
    } else if (words.every((w) => name.contains(w) || parent.contains(w))) {
      score += 70;
    } else {
      for (final w in words) {
        if (name.contains(w)) score += 25;
      }
      var parentHits = 0;
      for (final w in words) {
        if (parent.contains(w)) parentHits += 1;
      }
      score += parentHits * 10 < 20 ? parentHits * 10 : 20;
    }
    if (fullPath.contains(phrase)) score += 15;
    if (score > 0) scored.add((score: score, folder: folder));
  }
  scored.sort((a, b) =>
      b.score.compareTo(a.score) != 0
          ? b.score.compareTo(a.score)
          : a.folder.path.length.compareTo(b.folder.path.length) != 0
              ? a.folder.path.length.compareTo(b.folder.path.length)
              : a.folder.name.compareTo(b.folder.name));
  if (scored.isEmpty) return [];
  final best = scored.first.score;
  return scored
      .where((s) => s.score >= best - 20)
      .take(8)
      .map((s) => s.folder)
      .toList();
}

bool _isDirectory(String p) {
  try {
    return Directory(p).statSync().type == FileSystemEntityType.directory;
  } catch (_) {
    return false;
  }
}

String _ext(String path) {
  final name = path.split(Platform.pathSeparator).last;
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot).toLowerCase();
}
