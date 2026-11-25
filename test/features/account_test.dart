// Account + sync tests. No real Firebase: every test uses fakes.
// Live sign-in/sync is NOT covered here — there is no Firebase
// project yet (see FIREBASE-SETUP.md); that is tested by hand on
// both devices once the user creates the project.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dj/features/account/account.dart';
import 'package:dj/features/account/auth_service.dart';
import 'package:dj/features/account/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

// -- Fakes ------------------------------------------------------------

class FakeAuthBackend implements AuthBackend {
  final Map<String, String> _passwords = {}; // email -> password
  final Map<String, DjAuthUser> _users = {}; // email -> user
  DjAuthUser? _current;
  final _controller = StreamController<DjAuthUser?>.broadcast();

  @override
  Stream<DjAuthUser?> get authStateChanges => _controller.stream;

  @override
  DjAuthUser? get currentUser => _current;

  @override
  Future<DjAuthUser> signUp(String email, String password) async {
    if (_users.containsKey(email)) {
      throw const AuthFailure(
        'An account with this email already exists. Sign in instead.',
      );
    }
    if (password.length < 6) {
      throw const AuthFailure(
        'Choose a stronger password (at least 6 characters).',
      );
    }
    final user = DjAuthUser(uid: 'uid-$email', email: email);
    _users[email] = user;
    _passwords[email] = password;
    _setCurrent(user);
    return user;
  }

  @override
  Future<DjAuthUser> signIn(String email, String password) async {
    final user = _users[email];
    if (user == null) {
      throw const AuthFailure(
        'No DJ account with this email. Create one instead.',
      );
    }
    if (_passwords[email] != password) {
      throw const AuthFailure('Wrong password. Try again.');
    }
    _setCurrent(user);
    return user;
  }

  @override
  Future<void> signOut() async => _setCurrent(null);

  @override
  Future<void> deleteUser() async {
    if (_current != null) {
      _users.remove(_current!.email);
      _passwords.remove(_current!.email);
    }
    _setCurrent(null);
  }

  void _setCurrent(DjAuthUser? user) {
    _current = user;
    _controller.add(user);
  }
}

class FakeCloudStore implements CloudStore {
  final Map<String, Map<String, SyncedDoc>> store = {};
  final _watch = StreamController<MapEntry<String, SyncedDoc>>.broadcast();
  bool failFetch = false;
  int saveCount = 0;
  int deleteAllCount = 0;

  void emitRemote(String docId, SyncedDoc doc) =>
      _watch.add(MapEntry(docId, doc));

  @override
  Future<Map<String, SyncedDoc>> fetchAll(String uid) async {
    if (failFetch) throw StateError('offline');
    return Map<String, SyncedDoc>.from(store[uid] ?? {});
  }

  @override
  Future<void> save(String uid, String docId, SyncedDoc doc) async {
    validateSyncPayload(doc.data);
    (store[uid] ??= {})[docId] = doc;
    saveCount++;
  }

  @override
  Future<void> deleteAll(String uid) async {
    store.remove(uid);
    deleteAllCount++;
  }

  @override
  Stream<MapEntry<String, SyncedDoc>> watchAll(String uid) => _watch.stream;
}

class FakeLocalStore implements LocalStore {
  final Map<String, SyncedDoc> docs = {};
  bool wiped = false;

  @override
  SyncedDoc? readDoc(String docId) => docs[docId];

  @override
  void writeDoc(String docId, SyncedDoc doc) {
    validateSyncPayload(doc.data);
    docs[docId] = doc;
  }

  @override
  void wipeAll() {
    docs.clear();
    wiped = true;
  }
}

// -- Tests ------------------------------------------------------------

void main() {
  group('last-write-wins merge (pickNewer)', () {
    test('newer remote wins', () {
      final local = SyncedDoc(data: {'a': 1}, updatedAt: 100);
      final remote = SyncedDoc(data: {'a': 2}, updatedAt: 200);
      expect(pickNewer(local, remote), same(remote));
    });

    test('newer local wins', () {
      final local = SyncedDoc(data: {'a': 1}, updatedAt: 300);
      final remote = SyncedDoc(data: {'a': 2}, updatedAt: 200);
      expect(pickNewer(local, remote), same(local));
    });

    test('tie goes to remote, deterministically', () {
      final local = SyncedDoc(data: {'a': 1}, updatedAt: 100);
      final remote = SyncedDoc(data: {'a': 2}, updatedAt: 100);
      expect(pickNewer(local, remote), same(remote));
    });

    test('missing side loses', () {
      final doc = SyncedDoc(data: {'a': 1}, updatedAt: 100);
      expect(pickNewer(null, doc), same(doc));
      expect(pickNewer(doc, null), same(doc));
      expect(pickNewer(null, null), isNull);
    });
  });

  group('sync payload privacy', () {
    test('routines payload has only routines', () {
      final payload = buildRoutinesPayload('[{"name":"gym"}]');
      expect(payload.keys, ['routines']);
      validateSyncPayload(payload);
    });

    test('settings payload drops folder paths', () {
      final payload = buildSettingsPayload({
        'workerUrl': 'https://dj-worker.example.workers.dev',
        'provider': 'openai',
        'localModelKind': 'ollama',
        'localModelName': 'qwen3.5:9b',
        'startAtLogin': true,
        // Device-specific: must never survive.
        'folders': ['C:\\Users\\dj\\Desktop'],
        'folderPaths': ['C:\\Users\\dj\\Desktop'],
      });
      expect(payload.containsKey('folders'), isFalse);
      expect(payload.containsKey('folderPaths'), isFalse);
      expect(payload['workerUrl'],
          'https://dj-worker.example.workers.dev');
      expect(payload['provider'], 'openai');
      validateSyncPayload(payload);
    });

    test('summaries payload has only short summaries', () {
      final payload = buildSummariesPayload([
        {'id': 's1', 'text': 'Talked about gym routine.', 'updatedAt': 10},
      ]);
      expect(payload.keys, ['summaries']);
      expect((payload['summaries'] as List).single['text'],
          'Talked about gym routine.');
      validateSyncPayload(payload);
    });

    test('memory payload has only memory text', () {
      final payload = buildMemoryPayload(
        '- 2026-11-25 likes morning gym\n',
        [
          {'date': '2026-11-25', 'text': '- 09:00 gym done\n'},
        ],
      );
      expect(payload.keys, {'memoryMd', 'daily'});
      validateSyncPayload(payload);
    });

    test('forbidden keys are rejected, even nested', () {
      for (final bad in [
        {'transcript': 'full chat text...'},
        {'screenshot': 'base64...'},
        {'fileContents': 'secret file'},
        {'folders': ['/home/dj/Desktop']},
        {'data': {'fullTranscript': '...'}},
        {'summaries': [
          {'text': 'ok', 'screenshot': '...'},
        ]},
      ]) {
        expect(() => validateSyncPayload(bad), throwsStateError);
      }
    });
  });

  group('AuthService with a fake backend', () {
    late FakeAuthBackend backend;
    late AuthService auth;

    setUp(() {
      backend = FakeAuthBackend();
      auth = AuthService(backend: backend);
    });

    test('sign up then sign in works, wrong password is plain text', () async {
      final user = await auth.signUp('dj@example.com', 'secret123');
      expect(user.email, 'dj@example.com');
      expect(auth.isSignedIn, isTrue);
      await auth.signOut();
      expect(auth.isSignedIn, isFalse);
      await expectLater(
        auth.signIn('dj@example.com', 'nope'),
        throwsA(
          isA<AuthFailure>().having(
            (e) => e.message,
            'message',
            'Wrong password. Try again.',
          ),
        ),
      );
      final again = await auth.signIn('dj@example.com', 'secret123');
      expect(again.uid, user.uid);
    });

    test('second sign-up with the same email is a plain error', () async {
      await auth.signUp('dj@example.com', 'secret123');
      await expectLater(
        auth.signUp('dj@example.com', 'otherpass'),
        throwsA(
          isA<AuthFailure>().having(
            (e) => e.message,
            'message',
            contains('already exists'),
          ),
        ),
      );
    });

    test('deleteAccount wipes via the callback, then deletes the user',
        () async {
      String? wipedUid;
      final authWithWipe = AuthService(
        backend: backend,
        onBeforeDelete: (uid) async => wipedUid = uid,
      );
      final user = await authWithWipe.signUp('dj@example.com', 'secret123');
      await authWithWipe.deleteAccount();
      expect(wipedUid, user.uid);
      expect(authWithWipe.isSignedIn, isFalse);
    });
  });

  group('SyncService with fakes', () {
    late FakeCloudStore cloud;
    late FakeLocalStore local;
    late SyncService sync;
    const uid = 'uid-1';

    setUp(() {
      cloud = FakeCloudStore();
      local = FakeLocalStore();
      sync = SyncService(cloud: cloud, local: local);
    });

    tearDown(() => sync.dispose());

    test('startSync pulls a newer remote doc into local', () async {
      cloud.store[uid] = {
        SyncDocId.memory: const SyncedDoc(
          data: {
            'memoryMd': '- 2026-11-25 test fact\n',
            'daily': [],
          },
          updatedAt: 500,
        ),
      };
      local.docs[SyncDocId.memory] = const SyncedDoc(
        data: {'memoryMd': '- old\n', 'daily': []},
        updatedAt: 100,
      );
      await sync.startSync(uid);
      expect(sync.currentStatus, SyncStatus.synced);
      expect(
        local.docs[SyncDocId.memory]!.data['memoryMd'],
        '- 2026-11-25 test fact\n',
      );
    });

    test('pushNow uploads only local docs newer than remote', () async {
      cloud.store[uid] = {
        SyncDocId.routines: const SyncedDoc(
          data: {'routines': []},
          updatedAt: 900,
        ),
      };
      local.docs[SyncDocId.routines] = const SyncedDoc(
        data: {'routines': []},
        updatedAt: 100, // older: must NOT overwrite remote
      );
      local.docs[SyncDocId.settings] = const SyncedDoc(
        data: {'provider': 'openai'},
        updatedAt: 1000, // newer: must upload
      );
      await sync.startSync(uid);
      expect(
        cloud.store[uid]![SyncDocId.routines]!.updatedAt,
        900,
        reason: 'older local routines must not overwrite remote',
      );
      expect(
        cloud.store[uid]![SyncDocId.settings]!.data['provider'],
        'openai',
      );
    });

    test('live remote change applies while syncing', () async {
      await sync.startSync(uid);
      local.docs[SyncDocId.summaries] = const SyncedDoc(
        data: {'summaries': []},
        updatedAt: 100,
      );
      cloud.emitRemote(
        SyncDocId.summaries,
        const SyncedDoc(
          data: {
            'summaries': [
              {'id': 's1', 'text': 'Phone summary.', 'updatedAt': 200},
            ],
          },
          updatedAt: 200,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        (local.docs[SyncDocId.summaries]!.data['summaries'] as List)
            .single['text'],
        'Phone summary.',
      );
    });

    test('sign-out stops sync: later remote changes are ignored', () async {
      await sync.startSync(uid);
      await sync.stopSync();
      expect(sync.currentStatus, SyncStatus.offline);
      local.docs[SyncDocId.memory] = const SyncedDoc(
        data: {'memoryMd': '- local\n', 'daily': []},
        updatedAt: 100,
      );
      cloud.emitRemote(
        SyncDocId.memory,
        const SyncedDoc(
          data: {'memoryMd': '- remote\n', 'daily': []},
          updatedAt: 999,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        local.docs[SyncDocId.memory]!.data['memoryMd'],
        '- local\n',
        reason: 'no sync after sign-out',
      );
    });

    test('offline fetch failure still queues local docs for upload',
        () async {
      cloud.failFetch = true;
      local.docs[SyncDocId.settings] = const SyncedDoc(
        data: {'provider': 'openai'},
        updatedAt: 100,
      );
      await sync.startSync(uid);
      expect(cloud.store[uid]![SyncDocId.settings]!.data['provider'],
          'openai');
    });
  });

  group('Account facade with fakes', () {
    test('deleteEverything wipes cloud + local + the user', () async {
      final backend = FakeAuthBackend();
      final cloud = FakeCloudStore();
      final local = FakeLocalStore();
      final sync = SyncService(cloud: cloud, local: local);
      final auth = AuthService(
        backend: backend,
        onBeforeDelete: (uid) async {
          await cloud.deleteAll(uid);
          local.wipeAll();
        },
      );
      final account = Account(
        auth: auth,
        sync: sync,
        cloud: cloud,
        local: local,
      );
      final user = await account.signUp('dj@example.com', 'secret123');
      cloud.store[user.uid] = {
        SyncDocId.memory: const SyncedDoc(
          data: {'memoryMd': 'x', 'daily': []},
          updatedAt: 1,
        ),
      };
      local.docs[SyncDocId.memory] = const SyncedDoc(
        data: {'memoryMd': 'x', 'daily': []},
        updatedAt: 1,
      );
      expect(account.isSignedIn(), isTrue);
      expect(account.email, 'dj@example.com');
      expect(account.displayName, 'dj');

      await account.deleteEverything();

      expect(account.isSignedIn(), isFalse);
      expect(cloud.store.containsKey(user.uid), isFalse);
      expect(local.docs, isEmpty);
      expect(local.wiped, isTrue);
      expect(sync.currentStatus, SyncStatus.offline);
      sync.dispose();
    });

    test('signOut stops sync but keeps local data', () async {
      final backend = FakeAuthBackend();
      final cloud = FakeCloudStore();
      final local = FakeLocalStore();
      final sync = SyncService(cloud: cloud, local: local);
      final account = Account(
        auth: AuthService(backend: backend),
        sync: sync,
        cloud: cloud,
        local: local,
      );
      await account.signUp('dj@example.com', 'secret123');
      local.docs[SyncDocId.routines] = const SyncedDoc(
        data: {'routines': []},
        updatedAt: 1,
      );
      await account.signOut();
      expect(account.isSignedIn(), isFalse);
      expect(sync.currentStatus, SyncStatus.offline);
      expect(local.docs.containsKey(SyncDocId.routines), isTrue);
      sync.dispose();
    });
  });

  group('FileLocalStore (real files, temp dir)', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('dj-account-test');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('settings round-trip keeps folders out of the synced doc', () {
      final store = FileLocalStore(tmp.path);
      File('${tmp.path}/dj_config.json').writeAsStringSync(
        jsonEncode({
          'folders': [
            {'path': '/home/dj/Desktop', 'enabled': true},
          ],
          'localModel': {'kind': 'ollama', 'model': 'qwen3.5:9b'},
          'startAtLogin': true,
        }),
      );
      File('${tmp.path}/dj_cloud.json').writeAsStringSync(
        jsonEncode({
          'workerUrl': 'https://dj-worker.example.workers.dev',
          'provider': 'openai',
        }),
      );
      final doc = store.readDoc(SyncDocId.settings)!;
      expect(doc.data.containsKey('folders'), isFalse);
      expect(doc.data['workerUrl'],
          'https://dj-worker.example.workers.dev');
      expect(doc.data['localModelKind'], 'ollama');
    });

    test('memory round-trip and wipe keeps device folders', () {
      final store = FileLocalStore(tmp.path);
      File('${tmp.path}/MEMORY.md')
          .writeAsStringSync('- 2026-11-25 fact\n');
      Directory('${tmp.path}/memory').createSync();
      File('${tmp.path}/memory/2026-11-25.md')
          .writeAsStringSync('- 09:00 note\n');
      File('${tmp.path}/dj_config.json').writeAsStringSync(
        jsonEncode({
          'folders': [
            {'path': '/home/dj/Desktop', 'enabled': true},
          ],
        }),
      );
      final doc = store.readDoc(SyncDocId.memory)!;
      expect(doc.data['memoryMd'], contains('fact'));
      expect((doc.data['daily'] as List).single['date'], '2026-11-25');

      store.wipeAll();
      expect(File('${tmp.path}/MEMORY.md').existsSync(), isFalse);
      expect(Directory('${tmp.path}/memory').existsSync(), isFalse);
      // Device-specific folder list survives a wipe.
      final config = jsonDecode(
        File('${tmp.path}/dj_config.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect((config['folders'] as List).single['path'],
          '/home/dj/Desktop');
    });
  });
}
