// DJ Core tests — index service, duplicates, chat service,
// capability fallback, agent loop, chunking, models JSON.
import 'dart:io';

import 'package:dj/core/agent_loop.dart';
import 'package:dj/core/capability.dart';
import 'package:dj/core/models.dart';
import 'package:dj/core/text_utils.dart';
import 'package:dj/services/app_launcher.dart';
import 'package:dj/services/chat_service.dart';
import 'package:dj/services/duplicate_service.dart';
import 'package:dj/services/index_service.dart';
import 'package:dj/services/system_ops.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeSystemOps implements SystemOps {
  final String home;
  final List<String> openedFiles = [];
  final List<String> openedFolders = [];
  final List<String> openedApps = [];
  final List<String> trashed = [];
  FakeSystemOps(this.home);

  @override
  Future<({bool ok, String message})> openFile(String path) async {
    openedFiles.add(path);
    return (ok: true, message: 'Opened $path.');
  }

  @override
  Future<({bool ok, String message})> openFolder(String path) async {
    openedFolders.add(path);
    return (ok: true, message: 'Opened $path.');
  }

  @override
  Future<({bool ok, String message})> openApp(String exe, List<String> args) async {
    openedApps.add(exe);
    return (ok: true, message: 'Opened $exe.');
  }

  @override
  Future<void> deleteToTrash(List<String> paths) async {
    // Fake trash: actually remove the files (like the Recycle Bin
    // does from the app's point of view), and record them.
    for (final p in paths) {
      try {
        File(p).deleteSync();
      } catch (_) {}
    }
    trashed.addAll(paths);
  }

  @override
  Future<SystemStats> getSystemStats() async => SystemStats(
        cpuPercent: null,
        cpuCores: 4,
        totalMemBytes: 0,
        freeMemBytes: 0,
        uptimeSeconds: 0,
        platform: 'test',
        checkedAt: DateTime.now().toIso8601String(),
      );

  @override
  Future<bool> setStartAtLogin(bool enabled) async => enabled;

  @override
  String getHomeDir() => home;

  @override
  Future<String?> pickFolder() async => null;
}

void main() {
  group('chunking', () {
    test('chunkText 400 words, 50 overlap', () {
      final words = List.generate(900, (i) => 'w$i').join(' ');
      final chunks = chunkText(words);
      expect(chunks.length, 3);
      expect(chunks[0].split(' ').length, 400);
      expect(chunks[1].split(' ').first, 'w350');
      expect(chunks[2].split(' ').first, 'w700');
      expect(chunkText(''), isEmpty);
      expect(chunkText('one two'), ['one two']);
    });
    test('chunkPdfText tags pages', () {
      final chunks = chunkPdfText('page one words here now\fpage two words here now');
      expect(chunks.length, 2);
      expect(chunks[0], startsWith('[page 1] '));
      expect(chunks[1], startsWith('[page 2] '));
      expect(chunkPdfText('no page marks here'), chunkText('no page marks here'));
    });
    test('snippet centres on the query word', () {
      final text = '${'a ' * 100}needle in a haystack ${'b ' * 100}';
      final s = snippet(text, 'needle');
      expect(s, contains('needle'));
      expect(s.length, lessThanOrEqualTo(164));
    });
    test('countOccurrences is non-overlapping', () {
      expect(countOccurrences('aaa', 'aa'), 1);
      expect(countOccurrences('ababab', 'ab'), 3);
      expect(countOccurrences('x', ''), 0);
    });
  });

  group('index service', () {
    late Directory tmp;
    late Directory dataDir;
    late IndexService indexer;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('dj-index-');
      dataDir = Directory('${tmp.path}/dj_data')..createSync();
      final docs = Directory('${tmp.path}/Docs')..createSync();
      File('${docs.path}/virun-pitch.txt').writeAsStringSync(
          'Virun is a travel and tourism platform for India with local guides.');
      File('${docs.path}/notes.md').writeAsStringSync(
          'Shopping list: milk, bread, and a new keyboard for the laptop.');
      File('${docs.path}/report.pdf.txt').writeAsStringSync('Annual report figures.');
      indexer = IndexService(
          dataDir: dataDir.path, embedder: NotStartedEmbedder());
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('build + keyword search, name match wins', () async {
      final counts = await indexer.build(['${tmp.path}/Docs']);
      expect(counts.files, 3);
      expect(counts.folders, greaterThanOrEqualTo(1));
      expect(counts.vectorOk, isFalse); // no embedder yet
      expect(counts.keywordOnly, 3); // 3 chunks, no model
      final results = await indexer.search('virun pitch');
      expect(results, isNotEmpty);
      expect(results.first.name, 'virun-pitch.txt');
      expect(indexer.lastMeaning, 'ready'); // name match wins outright
      final byContent = await indexer.search('keyboard laptop');
      expect(byContent.first.name, 'notes.md');
      expect(await indexer.search('zzzqqq'), isEmpty);
    });
    test('search is keyword-only with the meaning note when no model', () async {
      await indexer.build(['${tmp.path}/Docs']);
      final results = await indexer.search('keyboard laptop');
      expect(results.first.note, contains('Meaning search is unavailable'));
    });
    test('incremental rebuild reuses unchanged files', () async {
      final c1 = await indexer.build(['${tmp.path}/Docs']);
      expect(c1.newCount, 3);
      final c2 = await indexer.build(['${tmp.path}/Docs']);
      expect(c2.reused, 3);
      expect(c2.newCount, 0);
      expect(c2.files, 3);
      // Change one file -> only it is re-read.
      File('${tmp.path}/Docs/notes.md')
          .writeAsStringSync('Changed content about trains.');
      final c3 = await indexer.build(['${tmp.path}/Docs']);
      expect(c3.reused, 2);
      expect(c3.newCount, 1);
      expect((await indexer.search('trains')).first.name, 'notes.md');
    });
    test('index persists to disk and reloads', () async {
      await indexer.build(['${tmp.path}/Docs']);
      final again = IndexService(
          dataDir: dataDir.path, embedder: NotStartedEmbedder());
      again.loadFromDisk();
      expect(again.hasIndex(), isTrue);
      expect((await again.search('virun')).first.name, 'virun-pitch.txt');
      expect(File('${dataDir.path}/keyword_index.json').existsSync(), isTrue);
    });
    test('listRecent newest first', () async {
      await indexer.build(['${tmp.path}/Docs']);
      final recent = indexer.listRecent(10);
      expect(recent.length, 3);
      expect(recent.first.mtime, greaterThanOrEqualTo(recent.last.mtime));
    });
    test('findFolders rankFolders scoring', () {
      final folders = [
        const IndexedFolder(path: '/home/u/AuPro/frontend', name: 'frontend', parent: '/home/u/AuPro'),
        const IndexedFolder(path: '/home/u/Other/frontend', name: 'frontend', parent: '/home/u/Other'),
        const IndexedFolder(path: '/home/u/AuPro', name: 'AuPro', parent: '/home/u'),
      ];
      expect(rankFolders(folders, 'frontend').length, 2);
      // Exact name wins; AuPro frontend ranks the AuPro one first.
      expect(rankFolders(folders, 'AuPro frontend').first.path,
          '/home/u/AuPro/frontend');
      expect(rankFolders(folders, 'AuPro').first.name, 'AuPro');
      expect(rankFolders(folders, 'zzz'), isEmpty);
      expect(rankFolders(folders, 'the folder'), isEmpty);
    });
    test('indexBuiltSummary exact shape', () {
      const c = IndexCounts(
        files: 10, folders: 2, chunks: 5, embedded: 4, keywordOnly: 1,
        skipped: 0, errors: 0, seconds: 1.5, vectorOk: true,
        reused: 3, newCount: 7, removed: 1,
      );
      expect(IndexService.indexBuiltSummary(c),
          'Index built: 10 files, 2 folders, 4 with meaning search, 1 keyword only, 7 new, 3 reused, 1 removed. Took 1.5s.');
    });
  });

  group('duplicates', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('dj-dup-'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('same size different content is NOT a duplicate', () async {
      final a = Directory('${tmp.path}/a')..createSync();
      final b = Directory('${tmp.path}/b')..createSync();
      File('${a.path}/f.txt').writeAsStringSync('AAAA');
      File('${b.path}/f.txt').writeAsStringSync('BBBB');
      final svc = DuplicateService();
      expect(await svc.find([tmp.path]), isEmpty);
    });
    test('identical files group, keeper first, wasted correct', () async {
      final a = Directory('${tmp.path}/a')..createSync();
      final b = Directory('${tmp.path}/b')..createSync();
      File('${a.path}/copy.txt').writeAsStringSync('same content here');
      File('${b.path}/copy.txt').writeAsStringSync('same content here');
      File('${a.path}/empty.txt').writeAsStringSync('');
      final svc = DuplicateService();
      final groups = await svc.find([tmp.path]);
      expect(groups.length, 1);
      expect(groups.first.files.length, 2);
      expect(groups.first.wasted, 17); // 'same content here' is 17 bytes
      expect(groups.first.files.first.path, endsWith('a${Platform.pathSeparator}copy.txt'));
    });
    test('merge keeps first copy, moves the rest, never overwrites', () {
      final a = Directory('${tmp.path}/a')..createSync();
      final target = Directory('${tmp.path}/Merged');
      File('${a.path}/x.txt').writeAsStringSync('data');
      final b = File('${tmp.path}/b.txt')..writeAsStringSync('data');
      final existing = File('${target.path}/b.txt')
        ..createSync(recursive: true);
      existing.writeAsStringSync('existing');
      final svc = DuplicateService();
      final r = svc.merge(['${a.path}/x.txt', b.path], target.path);
      expect(r.errors, isEmpty);
      expect(r.moved.length, 1);
      expect(File('${a.path}/x.txt').existsSync(), isTrue);
      expect(File('${target.path}/b-1.txt').existsSync(), isTrue);
      // <2 paths is blocked by the judge, not a silent no-op.
      final r2 = svc.merge(['${a.path}/x.txt'], target.path);
      expect(r2.moved, isEmpty);
      expect(r2.errors, isNotEmpty);
    });
    test('delete is judge-gated and goes to trash, never File.delete', () async {
      final ops = FakeSystemOps(tmp.path);
      final svc = DuplicateService(systemOps: ops);
      final logDir = Directory('${tmp.path}/Downloads')..createSync();
      // 0 targets -> blocked, nothing trashed.
      final blocked = await svc.deleteToRecycleBin(logDir.path, []);
      expect(blocked.deleted, isEmpty);
      expect(blocked.errors, isNotEmpty);
      expect(ops.trashed, isEmpty);
      // Real delete goes through the trash hook and logs it.
      final f = File('${tmp.path}/gone.txt')..writeAsStringSync('x');
      final ok = await svc.deleteToRecycleBin(logDir.path, [f.path]);
      expect(ok.deleted, [f.path]);
      expect(ops.trashed, [f.path]);
      expect(File(ok.logPath).readAsStringSync(), contains('Recycle Bin (deleted)'));
      // Gone file -> per-file error, not a crash.
      final gone = await svc.deleteToRecycleBin(logDir.path, [f.path]);
      expect(gone.errors.first, contains('already gone'));
    });
  });

  group('chat service', () {
    late Directory tmp;
    late FakeSystemOps ops;
    late ChatService chat;
    late IndexService indexer;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('dj-chat-');
      ops = FakeSystemOps(tmp.path);
      final dataDir = Directory('${tmp.path}/dj_data')..createSync();
      final docs = Directory('${tmp.path}/Docs')..createSync();
      File('${docs.path}/virun-pitch.txt').writeAsStringSync(
          'Virun is a travel and tourism platform for India with local guides.');
      indexer = IndexService(
          dataDir: dataDir.path, embedder: NotStartedEmbedder());
      await indexer.build(['${tmp.path}/Docs']);
      chat = ChatService(
          indexer: indexer, getFolders: () => ['${tmp.path}/Docs'], systemOps: ops);
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('help', () async {
      final r = await chat.handle('help');
      expect(r.kind, 'help');
      expect(r.text, contains('find my Virun pitch'));
    });
    test('search finds and reports count', () async {
      final r = await chat.handle('find my Virun pitch');
      expect(r.kind, 'search');
      expect(r is ChatResponseSearch, isTrue);
      expect((r as ChatResponseSearch).results.first.name, 'virun-pitch.txt');
    });
    test('search with no results gives the exact message', () async {
      final r = await chat.handle('find zzzqqq nothing');
      expect(r.kind, 'message');
      expect(r.text, contains("I could not find anything about 'zzzqqq nothing'"));
      expect(r.text, contains('Try different words'));
    });
    test('open opens results[0] via SystemOps', () async {
      final r = await chat.handle('open virun pitch');
      expect(r.kind, 'opened');
      expect(r.text, 'Opened virun-pitch.txt.');
      expect(ops.openedFiles.length, 1);
    });
    test('summarize returns summary + note', () async {
      final r = await chat.handle('summarize my Virun pitch');
      expect(r.kind, 'summary');
      final s = r as ChatResponseSummary;
      expect(s.fileName, 'virun-pitch.txt');
      expect(s.summary, contains('Virun'));
      expect(s.note, contains('DJ has no AI model'));
    });
    test('organize with no range asks for a range', () async {
      final r = await chat.handle('organize downloads');
      expect(r.kind, 'ask-range');
      expect(r.text, 'Which days should I organize in Downloads?');
    });
    test('list returns recent files', () async {
      final r = await chat.handle('list recent files');
      expect(r.kind, 'search');
      expect(r.text, 'Here are your newest indexed files:');
    });
    test('openApp routes through the launcher', () async {
      // On this Linux VM there is no notepad.exe on PATH, so the
      // exact not-found message is the correct behaviour (Windows
      // apps resolve on Windows). The launcher itself is covered
      // by the findOnPath test below.
      final r = await chat.handle('open notepad');
      expect(r.kind, 'message');
      expect(r.text, contains("I could not find an app called 'notepad'"));
    });
    test('app launcher findOnPath resolves a real PATH exe', () {
      final launcher = AppLauncher(ops);
      // 'sh' is on PATH on this Linux VM.
      expect(launcher.findOnPath('sh'), isNotNull);
      expect(launcher.findOnPath('definitely-not-a-real-exe-xyz'), isNull);
    });
    test('deleteDuplicates with 0 paths is judge-blocked', () async {
      final r = await chat.deleteDuplicates([]);
      expect(r.deleted, isEmpty);
      expect(r.errors, isNotEmpty);
      expect(ops.trashed, isEmpty);
    });
    test('splitFolderHint / preferInFolder', () {
      expect(splitFolderHint('index.html in AuPro').query, 'index.html');
      expect(splitFolderHint('index.html in AuPro').hint, 'AuPro');
      expect(splitFolderHint('index.html').hint, '');
      final results = [
        const SearchResult(path: '/x/other/index.html', name: 'index.html', folder: '/x/other', snippet: '', score: 1),
        const SearchResult(path: '/x/AuPro/index.html', name: 'index.html', folder: '/x/AuPro', snippet: '', score: 1),
      ];
      expect(preferInFolder(results, 'AuPro').first.path, '/x/AuPro/index.html');
    });
  });

  group('capability fallback', () {
    test('core only when nothing is up', () async {
      final mgr = CapabilityManager(
        probes: CapabilityProbes(
          checkLocal: () async =>
              const LocalModelHealth(available: false, reason: 'local model not running'),
          checkCloud: () async =>
              const CloudHealth(configured: false, valid: null, reason: 'no cloud key set'),
        ),
      );
      final s = await mgr.resolve(true);
      expect(s.layer, 'core');
      expect(s.message, 'Core only: local model not running');
    });
    test('expired cloud key + no local -> core with the exact message', () async {
      final mgr = CapabilityManager(
        probes: CapabilityProbes(
          checkLocal: () async =>
              const LocalModelHealth(available: false, reason: 'local model not running'),
          checkCloud: () async => const CloudHealth(
              configured: true,
              valid: false,
              statusCode: 401,
              reason: 'cloud key expired or invalid (401)'),
        ),
      );
      final s = await mgr.resolve(true);
      expect(s.layer, 'core');
      expect(s.message,
          'Core only: cloud key expired or invalid (401), local model not running');
    });
    test('local up wins; cloud invalid is noted', () async {
      final mgr = CapabilityManager(
        probes: CapabilityProbes(
          checkLocal: () async =>
              const LocalModelHealth(available: true, name: 'Ollama (qwen3.5:9b)'),
          checkCloud: () async => const CloudHealth(
              configured: true,
              valid: false,
              reason: 'cloud key expired or invalid (401)'),
        ),
      );
      final s = await mgr.resolve(true);
      expect(s.layer, 'local');
      expect(s.message,
          'Local model (Ollama (qwen3.5:9b)) — cloud key expired or invalid (401)');
    });
    test('valid cloud wins, notes local too', () async {
      final mgr = CapabilityManager(
        probes: CapabilityProbes(
          checkLocal: () async =>
              const LocalModelHealth(available: true, name: 'Ollama'),
          checkCloud: () async =>
              const CloudHealth(configured: true, valid: true),
        ),
      );
      final s = await mgr.resolve(true);
      expect(s.layer, 'cloud');
      expect(s.message, 'Cloud (local model also available)');
    });
    test('30 s cache: second resolve reuses the first', () async {
      var calls = 0;
      final mgr = CapabilityManager(
        probes: CapabilityProbes(
          checkLocal: () async {
            calls++;
            return const LocalModelHealth(available: false);
          },
          checkCloud: () async =>
              const CloudHealth(configured: false, valid: null),
        ),
      );
      await mgr.resolve();
      await mgr.resolve();
      expect(calls, 1);
      await mgr.resolve(true);
      expect(calls, 2);
    });
    test('isAuthError only 401/403', () {
      expect(isAuthError(401), isTrue);
      expect(isAuthError(403), isTrue);
      expect(isAuthError(500), isFalse);
      expect(isAuthError(null), isFalse);
    });
  });

  group('agent loop', () {
    test('coreThink calls the named tool then answers', () async {
      final loop = AgentLoop(maxSteps: 8);
      final tools = {
        'search': (String input) async => 'found: $input',
      };
      final r = await loop.run('search for virun pitch', tools);
      expect(r.done, isTrue);
      expect(r.steps.length, 2);
      expect(r.answer, contains('found:'));
    });
    test('loop is bounded at maxSteps', () async {
      var calls = 0;
      final loop = AgentLoop(maxSteps: 3);
      final r = await loop.run(
        'search for x',
        {'search': (String i) async {
          calls++;
          return 'hit';
        }},
        // A think fn that never finishes.
        (task, obs, tools) =>
            (tool: 'search', input: task, done: false, thought: 'again'),
      );
      expect(r.done, isFalse);
      expect(r.error, contains('stopped after 3 steps'));
      expect(calls, 3);
    });
    test('memory files append + read, newest 14 daily', () {
      final tmp = Directory.systemTemp.createTempSync('dj-mem-');
      try {
        final mem = MemoryFiles(tmp.path);
        mem.saveFact('learned X', DateTime.utc(2026, 11, 25));
        mem.appendDaily('did Y', DateTime.utc(2026, 11, 25, 10, 30));
        expect(mem.readMemory(), '- 2026-11-25 learned X\n');
        final content = mem.readContent();
        expect(content.daily.length, 1);
        expect(content.daily.first.date, '2026-11-25');
        expect(content.daily.first.text, contains('did Y'));
        expect(loadSkillPlaybooks('${tmp.path}/nope'), isEmpty);
        Directory('${tmp.path}/skills').createSync(recursive: true);
        File('${tmp.path}/skills/find-file.md')
            .writeAsStringSync('# Find a file\n\nNever guess a path.\n');
        final skills = loadSkillPlaybooks('${tmp.path}/skills');
        expect(skills.length, 1);
        expect(skills.first.id, 'find-file');
        expect(skills.first.title, 'Find a file');
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
    test('heartbeat ticks work without waiting', () async {
      var ticks = 0;
      final hb = Heartbeat(intervalMs: 30 * 60 * 1000, work: () => ticks++);
      await hb.tick();
      expect(ticks, 1);
      hb.start();
      expect(hb.running, isTrue);
      hb.stop();
      expect(hb.running, isFalse);
    });
  });

  group('models JSON roundtrip', () {
    test('AppConfig / ChatResponse / IndexCounts keep field names', () {
      const cfg = AppConfig(folders: [FolderEntry(path: '/x/Downloads', enabled: true)]);
      final json = cfg.toJson();
      expect(json['folders'][0]['path'], '/x/Downloads');
      expect(AppConfig.fromJson(json).folders.first.enabled, isTrue);
      const counts = IndexCounts(
          files: 1, folders: 1, chunks: 1, embedded: 0, keywordOnly: 1,
          skipped: 0, errors: 0, seconds: 0.5, vectorOk: false);
      expect(counts.toJson()['keywordOnly'], 1);
      final resp = ChatResponse.fromJson({
        'kind': 'organize-plan',
        'text': 't',
        'label': 'today',
        'range': {'kind': 'today'},
        'plan': [
          {'name': 'a.txt', 'old': '/a/a.txt', 'new': '/a/b.txt', 'folder': 'Documents'}
        ],
      });
      expect(resp, isA<ChatResponseOrganizePlan>());
      expect((resp as ChatResponseOrganizePlan).range, isA<OrganizeRangeToday>());
    });
  });
}
