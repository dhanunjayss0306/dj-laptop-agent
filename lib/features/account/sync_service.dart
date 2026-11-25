// DJ sync: the same DJ context on the laptop and the phone.
//
// One Firebase project, one account: the laptop and the phone sign in
// with the same DJ login and share the documents under users/{uid}/:
//
//   users/{uid}/context/routines   — routines.json
//   users/{uid}/context/settings   — syncable dj_config.json parts only
//   users/{uid}/context/summaries  — short conversation summaries
//   users/{uid}/context/memory     — MEMORY.md + daily notes
//
// PRIVACY — what sync NEVER uploads (enforced by [validateSyncPayload]
// and covered by tests in test/features/account_test.dart):
//   - file contents (DJ never uploads your files)
//   - full chat transcripts (only short summaries)
//   - screenshots (never)
//   - folder paths (device-specific; they stay local)
//   - passwords, API keys, or any credential (never)
// Only the four documents above, each a small JSON map, ever leave
// the device.
//
// CONFLICT RULE: last-write-wins, per document, by the updatedAt
// timestamp (milliseconds since epoch). Ties go to the remote copy,
// so the rule is deterministic. See [pickNewer].
//
// OFFLINE: Firestore's built-in offline persistence is enabled
// (see [FirestoreCloudStore]), so writes made offline are queued on
// the device and synced when the connection comes back. No DJ code
// has to handle reconnects.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';

/// Sync state, as the UI shows it.
enum SyncStatus { synced, syncing, offline, error }

/// The four synced documents. One Firestore document each, under
/// users/{uid}/context/{docId}.
class SyncDocId {
  static const String routines = 'routines';
  static const String settings = 'settings';
  static const String summaries = 'summaries';
  static const String memory = 'memory';

  static const List<String> all = [routines, settings, summaries, memory];
}

/// One synced document: its data plus when it was last written.
/// [updatedAt] is milliseconds since epoch, local clock.
class SyncedDoc {
  final Map<String, dynamic> data;
  final int updatedAt;
  const SyncedDoc({required this.data, required this.updatedAt});

  Map<String, dynamic> toJson() => {'updatedAt': updatedAt, 'data': data};

  factory SyncedDoc.fromJson(Map<String, dynamic> json) {
    final data = json['data'];
    return SyncedDoc(
      data: data is Map<String, dynamic>
          ? Map<String, dynamic>.from(data)
          : <String, dynamic>{},
      updatedAt: json['updatedAt'] is num
          ? (json['updatedAt'] as num).toInt()
          : 0,
    );
  }
}

/// Last-write-wins, per document. Returns the newer of [local] and
/// [remote] (null means "does not exist"). On an exact tie the remote
/// copy wins, so the result is the same on both devices.
SyncedDoc? pickNewer(SyncedDoc? local, SyncedDoc? remote) {
  if (local == null) return remote;
  if (remote == null) return local;
  return remote.updatedAt >= local.updatedAt ? remote : local;
}

// -- Payload safety ---------------------------------------------------

/// Keys that must never appear in a synced payload. If any of these
/// shows up, the payload is rejected instead of uploaded.
const Set<String> forbiddenSyncKeys = {
  'fileContents',
  'fileContent',
  'fileBytes',
  'filePath',
  'filePaths',
  'folders',
  'folderPaths',
  'transcript',
  'fullTranscript',
  'chatTranscript',
  'screenshot',
  'screenshots',
  'imageData',
  'password',
  'apiKey',
  'token',
};

/// Throws [StateError] if [payload] (or anything nested in it)
/// contains a forbidden key. Called before every upload.
void validateSyncPayload(Map<String, dynamic> payload) {
  void check(dynamic value) {
    if (value is Map) {
      for (final entry in value.entries) {
        if (entry.key is String &&
            forbiddenSyncKeys.contains(entry.key as String)) {
          throw StateError(
            'Sync payload must never contain "${entry.key}". '
            'See the privacy note at the top of sync_service.dart.',
          );
        }
        check(entry.value);
      }
    } else if (value is List) {
      for (final item in value) {
        check(item);
      }
    }
  }

  check(payload);
}

// -- Payload builders (pure: easy to test) ----------------------------

/// routines.json (a JSON list or object) -> the routines document.
/// Only the parsed routines go in; never file paths or contents.
Map<String, dynamic> buildRoutinesPayload(String routinesJson) {
  try {
    final decoded = jsonDecode(routinesJson);
    if (decoded is List || decoded is Map) {
      return {'routines': decoded};
    }
  } catch (_) {
    // Not JSON: keep the raw text, still only routines.
  }
  return {'routinesText': routinesJson};
}

/// The syncable parts of dj_config.json + dj_cloud.json.
/// Folder paths are device-specific and are NEVER included.
/// [fields] is the raw config map; only allowlisted keys survive.
Map<String, dynamic> buildSettingsPayload(Map<String, dynamic> fields) {
  final out = <String, dynamic>{};
  final workerUrl = fields['workerUrl'];
  if (workerUrl is String && workerUrl.isNotEmpty) {
    out['workerUrl'] = workerUrl;
  }
  final provider = fields['provider'];
  if (provider is String && provider.isNotEmpty) {
    out['provider'] = provider;
  }
  final localModelKind = fields['localModelKind'];
  if (localModelKind is String && localModelKind.isNotEmpty) {
    out['localModelKind'] = localModelKind;
  }
  final localModelName = fields['localModelName'];
  if (localModelName is String && localModelName.isNotEmpty) {
    out['localModelName'] = localModelName;
  }
  final startAtLogin = fields['startAtLogin'];
  if (startAtLogin is bool) out['startAtLogin'] = startAtLogin;
  return out;
}

/// Short conversation summaries only: [{id, text, updatedAt}].
/// [summaries] must already be short text — never full transcripts.
Map<String, dynamic> buildSummariesPayload(
  List<Map<String, dynamic>> summaries,
) {
  return {
    'summaries': summaries
        .map((s) => {
              'id': s['id'] as String? ?? '',
              'text': s['text'] as String? ?? '',
              'updatedAt': s['updatedAt'] is num
                  ? (s['updatedAt'] as num).toInt()
                  : 0,
            })
        .toList(),
  };
}

/// MEMORY.md + daily notes -> the memory document.
Map<String, dynamic> buildMemoryPayload(
  String memoryMd,
  List<Map<String, String>> daily,
) {
  return {
    'memoryMd': memoryMd,
    'daily': daily
        .map((d) => {'date': d['date'] ?? '', 'text': d['text'] ?? ''})
        .toList(),
  };
}

// -- Cloud store ------------------------------------------------------

/// The cloud side of sync. The real one is Firestore; tests use a
/// fake. All data is already validated by [validateSyncPayload]
/// before it reaches here.
abstract class CloudStore {
  /// All remote documents for [uid], by doc id.
  Future<Map<String, SyncedDoc>> fetchAll(String uid);

  /// Save one document for [uid].
  Future<void> save(String uid, String docId, SyncedDoc doc);

  /// Delete every document for [uid], including the profile doc.
  Future<void> deleteAll(String uid);

  /// Remote changes as they arrive: (docId, new doc). Used by
  /// [SyncService.startSync] for live sync.
  Stream<MapEntry<String, SyncedDoc>> watchAll(String uid);
}

/// Firestore implementation of [CloudStore].
/// Layout: users/{uid}/context/{docId}, plus users/{uid} (profile).
class FirestoreCloudStore implements CloudStore {
  FirestoreCloudStore([FirebaseFirestore? firestore])
      : _firestore = firestore ?? FirebaseFirestore.instance {
    // Offline persistence: writes made offline are queued on the
    // device and synced when back online. On mobile this is the
    // default; setting it explicitly keeps Windows the same.
    try {
      _firestore.settings = const Settings(persistenceEnabled: true);
    } catch (_) {
      // Settings can only be set before first use; if something
      // already touched Firestore, the default still applies.
    }
  }

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> _context(String uid) =>
      _firestore.collection('users').doc(uid).collection('context');

  @override
  Future<Map<String, SyncedDoc>> fetchAll(String uid) async {
    final snap = await _context(uid).get();
    return {
      for (final doc in snap.docs) doc.id: SyncedDoc.fromJson(doc.data()),
    };
  }

  @override
  Future<void> save(String uid, String docId, SyncedDoc doc) async {
    validateSyncPayload(doc.data);
    await _context(uid).doc(docId).set(doc.toJson());
  }

  @override
  Future<void> deleteAll(String uid) async {
    final snap = await _context(uid).get();
    final batch = _firestore.batch();
    for (final doc in snap.docs) {
      batch.delete(doc.reference);
    }
    batch.delete(_firestore.collection('users').doc(uid));
    await batch.commit();
  }

  @override
  Stream<MapEntry<String, SyncedDoc>> watchAll(String uid) {
    return _context(uid).snapshots().expand(
          (snap) => snap.docChanges.map(
            (c) => MapEntry(c.doc.id, SyncedDoc.fromJson(c.doc.data()!)),
          ),
        );
  }
}

// -- Local store ------------------------------------------------------

/// The device side of sync: the four documents as local files in
/// DJ's data dir. Folder paths never pass through here as sync data.
abstract class LocalStore {
  SyncedDoc? readDoc(String docId);
  void writeDoc(String docId, SyncedDoc doc);
  void wipeAll();
}

/// File implementation of [LocalStore].
///   routines -> routines.json
///   settings -> dj_config.json (localModel, startAtLogin) +
///               dj_cloud.json (workerUrl, provider)
///   summaries -> summaries.json
///   memory   -> MEMORY.md + memory/YYYY-MM-DD.md (newest 14)
class FileLocalStore implements LocalStore {
  FileLocalStore(this.dataDir);

  final String dataDir;
  String get _sep => Platform.pathSeparator;
  String _path(String name) => '$dataDir$_sep$name';

  int _mtime(File file) {
    try {
      return file.statSync().modified.millisecondsSinceEpoch;
    } catch (_) {
      return 0;
    }
  }

  Map<String, dynamic> _readJsonFile(String name) {
    try {
      final decoded = jsonDecode(File(_path(name)).readAsStringSync());
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return {};
  }

  void _writeJsonFile(String name, Map<String, dynamic> json) {
    final file = File(_path(name));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(json),
      encoding: utf8,
    );
  }

  @override
  SyncedDoc? readDoc(String docId) {
    switch (docId) {
      case SyncDocId.routines:
        final file = File(_path('routines.json'));
        if (!file.existsSync()) return null;
        return SyncedDoc(
          data: buildRoutinesPayload(file.readAsStringSync()),
          updatedAt: _mtime(file),
        );
      case SyncDocId.settings:
        final config = _readJsonFile('dj_config.json');
        final cloud = _readJsonFile('dj_cloud.json');
        final fields = <String, dynamic>{
          'workerUrl': cloud['workerUrl'],
          'provider': cloud['provider'],
          'localModelKind': (config['localModel'] as Map?)?['kind'],
          'localModelName': (config['localModel'] as Map?)?['model'],
          'startAtLogin': config['startAtLogin'],
        };
        final data = buildSettingsPayload(fields);
        final newest = [
          _mtime(File(_path('dj_config.json'))),
          _mtime(File(_path('dj_cloud.json'))),
        ].reduce((a, b) => a > b ? a : b);
        if (data.isEmpty && newest == 0) return null;
        return SyncedDoc(data: data, updatedAt: newest);
      case SyncDocId.summaries:
        final file = File(_path('summaries.json'));
        if (!file.existsSync()) return null;
        final raw = _readJsonFile('summaries.json');
        final list = raw['summaries'];
        final summaries = list is List
            ? list
                .whereType<Map<String, dynamic>>()
                .toList()
            : <Map<String, dynamic>>[];
        return SyncedDoc(
          data: buildSummariesPayload(summaries),
          updatedAt: _mtime(file),
        );
      case SyncDocId.memory:
        final memoryFile = File(_path('MEMORY.md'));
        final memoryMd =
            memoryFile.existsSync() ? memoryFile.readAsStringSync() : '';
        final daily = <Map<String, String>>[];
        final dir = Directory(_path('memory'));
        try {
          final names = dir
              .listSync()
              .whereType<File>()
              .map((f) => f.path.split(_sep).last)
              .where((n) => RegExp(r'^\d{4}-\d{2}-\d{2}\.md$').hasMatch(n))
              .toList()
            ..sort((a, b) => b.compareTo(a));
          for (final name in names.take(14)) {
            daily.add({
              'date': name.substring(0, 10),
              'text': File('${dir.path}$_sep$name').readAsStringSync(),
            });
          }
        } catch (_) {}
        if (memoryMd.isEmpty && daily.isEmpty) return null;
        return SyncedDoc(
          data: buildMemoryPayload(memoryMd, daily),
          updatedAt: _mtime(memoryFile),
        );
    }
    return null;
  }

  @override
  void writeDoc(String docId, SyncedDoc doc) {
    validateSyncPayload(doc.data);
    switch (docId) {
      case SyncDocId.routines:
        final routines = doc.data['routines'] ?? doc.data['routinesText'];
        final file = File(_path('routines.json'));
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(
          routines is String
              ? routines
              : const JsonEncoder.withIndent('  ').convert(routines ?? []),
          encoding: utf8,
        );
      case SyncDocId.settings:
        final config = _readJsonFile('dj_config.json');
        final cloud = _readJsonFile('dj_cloud.json');
        final data = doc.data;
        if (data['workerUrl'] is String || data['provider'] is String) {
          if (data['workerUrl'] is String) {
            cloud['workerUrl'] = data['workerUrl'];
          }
          if (data['provider'] is String) {
            cloud['provider'] = data['provider'];
          }
          _writeJsonFile('dj_cloud.json', cloud);
        }
        var changed = false;
        if (data['localModelKind'] is String) {
          config['localModel'] = {
            'kind': data['localModelKind'],
            if (data['localModelName'] is String)
              'model': data['localModelName'],
          };
          changed = true;
        }
        if (data['startAtLogin'] is bool) {
          config['startAtLogin'] = data['startAtLogin'];
          changed = true;
        }
        if (changed) _writeJsonFile('dj_config.json', config);
      case SyncDocId.summaries:
        _writeJsonFile('summaries.json', doc.data);
      case SyncDocId.memory:
        final memoryMd = doc.data['memoryMd'] as String? ?? '';
        final file = File(_path('MEMORY.md'));
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(memoryMd, encoding: utf8);
        final daily = doc.data['daily'];
        if (daily is List) {
          final dir = Directory(_path('memory'));
          dir.createSync(recursive: true);
          for (final entry in daily.whereType<Map<String, dynamic>>()) {
            final date = entry['date'] as String?;
            final text = entry['text'] as String?;
            if (date == null || text == null) continue;
            File('${dir.path}$_sep$date.md')
                .writeAsStringSync(text, encoding: utf8);
          }
        }
    }
  }

  @override
  void wipeAll() {
    // Deletes DJ's synced local data: routines, summaries, memory,
    // and the syncable settings. Device-specific config (the folder
    // list in dj_config.json) is left alone — it belongs to this
    // device, not the account.
    for (final name in [
      'routines.json',
      'summaries.json',
      'MEMORY.md',
      'dj_cloud.json',
    ]) {
      try {
        File(_path(name)).deleteSync();
      } catch (_) {}
    }
    try {
      Directory(_path('memory')).deleteSync(recursive: true);
    } catch (_) {}
    // Strip the syncable fields out of dj_config.json, keep folders.
    try {
      final config = _readJsonFile('dj_config.json');
      config.remove('localModel');
      config.remove('startAtLogin');
      if (config.isNotEmpty) _writeJsonFile('dj_config.json', config);
    } catch (_) {}
  }
}

// -- Sync service -----------------------------------------------------

/// Syncs DJ's context between this device and Firestore.
///
/// Lifecycle: [startSync] after sign-in, [stopSync] on sign-out.
/// [pushNow]/[pullNow] for a manual sync (e.g. a "Sync now" button).
/// [status] reports synced / syncing / offline / error.
class SyncService {
  SyncService({required CloudStore cloud, required LocalStore local})
      : _cloud = cloud,
        _local = local;

  final CloudStore _cloud;
  final LocalStore _local;

  String? _uid;
  String? get uid => _uid;

  final _statusController = StreamController<SyncStatus>.broadcast();
  Stream<SyncStatus> get status => _statusController.stream;
  SyncStatus _current = SyncStatus.offline;
  SyncStatus get currentStatus => _current;

  StreamSubscription<MapEntry<String, SyncedDoc>>? _watchSub;
  bool _running = false;

  void _setStatus(SyncStatus value) {
    _current = value;
    if (!_statusController.isClosed) _statusController.add(value);
  }

  /// Start syncing for [uid] (call right after sign-in). Pulls newer
  /// remote documents, pushes newer local ones, then listens live.
  Future<void> startSync(String uid) async {
    await stopSync();
    _uid = uid;
    _running = true;
    _setStatus(SyncStatus.syncing);
    _watchSub = _cloud.watchAll(uid).listen(
      (event) => _applyRemote(event.key, event.value),
      onError: (_) => _setStatus(SyncStatus.error),
    );
    await pullNow();
    await pushNow();
    if (_running) _setStatus(SyncStatus.synced);
  }

  /// Stop syncing (call on sign-out). Nothing is uploaded after this.
  Future<void> stopSync() async {
    _running = false;
    await _watchSub?.cancel();
    _watchSub = null;
    _uid = null;
    _setStatus(SyncStatus.offline);
  }

  /// Upload local documents that are newer than the remote copies.
  /// Works offline: Firestore queues the writes and sends them when
  /// the connection comes back.
  Future<void> pushNow() async {
    final uid = _uid;
    if (uid == null) return;
    _setStatus(SyncStatus.syncing);
    try {
      final remote = await _cloud.fetchAll(uid);
      for (final docId in SyncDocId.all) {
        final local = _local.readDoc(docId);
        if (local == null) continue;
        final remoteDoc = remote[docId];
        if (remoteDoc == null || local.updatedAt > remoteDoc.updatedAt) {
          await _cloud.save(uid, docId, local);
        }
      }
      if (_running) _setStatus(SyncStatus.synced);
    } catch (_) {
      // Offline (or fetch failed): push everything local anyway so
      // Firestore's offline queue holds it. Last-write-wins is
      // re-applied on the next pull.
      try {
        for (final docId in SyncDocId.all) {
          final local = _local.readDoc(docId);
          if (local != null) await _cloud.save(uid, docId, local);
        }
        if (_running) _setStatus(SyncStatus.synced);
      } catch (_) {
        if (_running) _setStatus(SyncStatus.error);
      }
    }
  }

  /// Download remote documents that are newer than the local copies.
  Future<void> pullNow() async {
    final uid = _uid;
    if (uid == null) return;
    _setStatus(SyncStatus.syncing);
    try {
      final remote = await _cloud.fetchAll(uid);
      for (final entry in remote.entries) {
        _applyRemote(entry.key, entry.value);
      }
      if (_running) _setStatus(SyncStatus.synced);
    } catch (_) {
      if (_running) _setStatus(SyncStatus.error);
    }
  }

  void _applyRemote(String docId, SyncedDoc remoteDoc) {
    if (!SyncDocId.all.contains(docId)) return;
    final local = _local.readDoc(docId);
    if (pickNewer(local, remoteDoc) == remoteDoc &&
        local?.updatedAt != remoteDoc.updatedAt) {
      _local.writeDoc(docId, remoteDoc);
    }
  }

  void dispose() {
    _watchSub?.cancel();
    _statusController.close();
  }
}
