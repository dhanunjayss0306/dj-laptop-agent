// DJ Core tests — brain routing, judge, workspace guard, router,
// voice, summarize, organize range parsing, config, hashing.
import 'dart:io';
import 'dart:typed_data';

import 'package:dj/core/brain.dart';
import 'package:dj/core/config.dart';
import 'package:dj/core/hashing.dart';
import 'package:dj/core/judge.dart';
import 'package:dj/core/models.dart';
import 'package:dj/core/router.dart';
import 'package:dj/core/security.dart';
import 'package:dj/core/voice_core.dart';
import 'package:dj/services/organize_service.dart';
import 'package:dj/services/summarize_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('brain routing order', () {
    final brain = BrainService();
    test('empty -> help', () {
      expect(brain.decide('').action, 'help');
      expect(brain.decide('   ').action, 'help');
    });
    test('help phrases -> help', () {
      expect(brain.decide('help').action, 'help');
      expect(brain.decide('what can you do').action, 'help');
      expect(brain.decide('help me please').action, 'help');
    });
    test('duplicates wins over organize', () {
      final a = brain.decide('organize my duplicates');
      expect(a.action, 'duplicates');
    });
    test('duplicates merge/delete query', () {
      expect(brain.decide('find duplicates').query, '');
      expect(brain.decide('merge the duplicates').query, 'merge');
      expect(brain.decide('delete the extra copies').query, 'delete');
      expect(brain.decide('same file copies').action, 'duplicates');
    });
    test('organize range text', () {
      expect(brain.decide("organize yesterday's Downloads").action, 'organize');
      expect(brain.decide("organize yesterday's Downloads").query, 'yesterday');
      expect(brain.decide('organize all downloads').query, 'all');
    });
    test('summarize strips the verb', () {
      final a = brain.decide('summarize my Virun pitch');
      expect(a.action, 'summarize');
      expect(a.query, 'my virun pitch');
    });
    test('folder beats open', () {
      final a = brain.decide('open the frontend folder');
      expect(a.action, 'openFolder');
      expect(a.query, 'frontend');
      final b = brain.decide('open that related folder in frontend');
      expect(b.query, 'frontend');
    });
    test('open known app', () {
      expect(brain.decide('open notepad').action, 'openApp');
      expect(brain.decide('open notepad').query, 'notepad');
    });
    test('open known folder name', () {
      final a = brain.decide('open frontend', ['frontend']);
      expect(a.action, 'openFolder');
      expect(a.query, 'frontend');
    });
    test('find/search prefixes', () {
      expect(brain.decide('find my notes').action, 'search');
      expect(brain.decide('find my notes').query, 'my notes');
      expect(brain.decide('where is my pitch').action, 'search');
      expect(brain.decide('show me the report').action, 'search');
    });
    test('list prefix', () {
      expect(brain.decide('list recent files').action, 'list');
    });
    test('default is search', () {
      final a = brain.decide('Virun pitch');
      expect(a.action, 'search');
      expect(a.query, 'Virun pitch');
    });
    test('help text is verbatim', () {
      expect(helpText.contains('find my Virun pitch'), isTrue);
      expect(helpText.contains('organize yesterday'), isTrue);
      expect(helpText.contains('list recent files'), isTrue);
    });
    test('extractFolderQuery examples', () {
      expect(extractFolderQuery('open AuPro frontend folder'), 'AuPro frontend');
      expect(extractFolderQuery('open the frontend folder in AuPro'), 'frontend AuPro');
      expect(extractFolderQuery('find a folder'), '');
      expect(extractFolderQuery('find my notes'), isNull);
    });
  });

  group('judge scoring', () {
    test('clear non-destructive action scores 5', () {
      final r = judgeAction(const JudgeInput(
          kind: 'reply', text: 'find my notes', destructive: false));
      expect(r.score, 5);
      expect(r.blocked, isEmpty);
      expect(r.needsConfirm, isFalse);
    });
    test('destructive with 0 targets is blocked', () {
      final r = judgeAction(const JudgeInput(
          kind: 'delete',
          text: 'delete the extra copies',
          destructive: true,
          targetCount: 0));
      expect(r.blocked, isNotEmpty);
      expect(r.blocked.first, contains('no target named'));
      expect(r.score, 1.2); // 0.7*0 + 0.3*4
      expect(r.needsConfirm, isTrue);
    });
    test('empty text is blocked', () {
      final r = judgeAction(
          const JudgeInput(kind: 'reply', text: '', destructive: false));
      expect(r.blocked, contains('nothing to act on'));
      expect(r.score, 1.5); // 0.7*0 + 0.3*5
    });
    test('destructive always needs confirm even at high score', () {
      final r = judgeAction(const JudgeInput(
          kind: 'delete',
          text: 'delete the extra copies',
          destructive: true,
          targetCount: 2));
      expect(r.needsConfirm, isTrue);
      expect(r.warnings, contains('destructive: needs your confirm before anything runs'));
      expect(r.score, 4.7); // 0.7*5 + 0.3*4
    });
    test('>50 targets warns', () {
      final r = judgeAction(const JudgeInput(
          kind: 'delete',
          text: 'delete the extra copies',
          destructive: true,
          targetCount: 51));
      expect(r.warnings.any((w) => w.contains('51 files')), isTrue);
      expect(r.score, 2.6); // 0.7*2 + 0.3*4
    });
    test('send is always manual', () {
      final r = judgeAction(
          const JudgeInput(kind: 'send', text: 'send the report', destructive: false));
      expect(r.needsConfirm, isTrue);
      expect(r.warnings, contains('sending is always manual — DJ drafts, you press send'));
    });
    test('goal mismatch warns and caps goal score', () {
      final r = judgeAction(const JudgeInput(
          kind: 'reply',
          text: 'find my notes',
          destructive: false,
          goal: 'organize downloads'));
      expect(r.warnings, contains('the plan does not clearly match the goal you stated'));
      expect(r.score, 3.6); // 0.7*3 + 0.3*5
    });
  });

  group('workspace guard', () {
    late Directory tmp;
    late WorkspaceGuard guard;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('dj-guard-');
      Directory('${tmp.path}/a').createSync();
      Directory('${tmp.path}/b').createSync();
      guard = WorkspaceGuard(['${tmp.path}/a', '${tmp.path}/b']);
    });
    tearDown(() => tmp.deleteSync(recursive: true));
    test('inside a root is allowed', () {
      expect(guard.resolve('${tmp.path}/a/file.txt'), isNotNull);
      expect(guard.resolve('${tmp.path}/a'), isNotNull);
      expect(guard.isAllowed('${tmp.path}/b/deep/file.txt'), isTrue);
    });
    test('.. escapes are denied', () {
      expect(guard.resolve('${tmp.path}/a/../b/secret.txt'), isNotNull); // resolves into b, allowed
      expect(guard.resolve('${tmp.path}/a/../../etc/passwd'), isNull);
      expect(guard.resolve('${tmp.path}/a/..'), isNull); // tmp itself, not a root
    });
    test('absolute paths outside every root are denied', () {
      expect(guard.resolve('/etc/passwd'), isNull);
      expect(guard.resolve('${tmp.path}/other/file.txt'), isNull);
    });
    test('relative paths and empty are denied', () {
      expect(guard.resolve('a/file.txt'), isNull);
      expect(guard.resolve(''), isNull);
    });
    test('resolveUnder stays inside the root', () {
      expect(guard.resolveUnder('${tmp.path}/a', 'sub/file.txt'), isNotNull);
      expect(guard.resolveUnder('${tmp.path}/a', '../b/file.txt'), isNotNull);
      expect(guard.resolveUnder('${tmp.path}/a', '../../etc/passwd'), isNull);
    });
    test('core provider is always healthy with the fixed reply', () async {
      final core = CoreProvider();
      expect(await core.health(), isTrue);
      expect(
          await core.chat('anything'),
          'Core only: I can find, open, organise, and summarise your files with rules — no model is running, so I cannot chat freely.');
      final registry = ProviderRegistry();
      expect(registry.defaultProvider().id, 'core');
      expect(registry.get('core'), isNotNull);
    });
  });

  group('router classification', () {
    test('image words -> image 0.9', () {
      final c = classifyRequest('show me that photo');
      expect(c.type, 'image');
      expect(c.confidence, 0.9);
      expect(c.route, ['read-image', 'describe', 'search']);
    });
    test('voice flag -> voice 0.9', () {
      final c = classifyRequest('find my notes', isVoice: true);
      expect(c.type, 'voice');
      expect(c.route, ['transcribe', 'classify', 'answer', 'speak']);
    });
    test('system words -> system 0.85', () {
      final c = classifyRequest('how much ram is free');
      expect(c.type, 'system');
      expect(c.confidence, 0.85);
      expect(c.route, ['classify', 'system-info']);
    });
    test('file words -> file 0.8', () {
      final c = classifyRequest('find my notes');
      expect(c.type, 'file');
      expect(c.confidence, 0.8);
      expect(c.route, ['classify', 'search', 'open']);
    });
    test('anything else -> text 0.6', () {
      final c = classifyRequest('hello there');
      expect(c.type, 'text');
      expect(c.confidence, 0.6);
      expect(c.route, ['classify', 'answer']);
    });
    test('serviceGraphFor covers all types', () {
      expect(serviceGraphFor('file'), ['classify', 'search', 'open']);
      expect(serviceGraphFor('text'), ['classify', 'answer']);
      expect(serviceGraphFor('voice'),
          ['transcribe', 'classify', 'answer', 'speak']);
      expect(serviceGraphFor('image'), ['read-image', 'describe', 'search']);
      expect(serviceGraphFor('system'), ['classify', 'system-info']);
    });
  });

  group('voice parseAddressed', () {
    test('DJ, ... is addressed', () {
      final r = parseAddressed('DJ, find my notes');
      expect(r.addressed, isTrue);
      expect(r.query, 'find my notes');
      expect(r.wakeWord, 'dj');
    });
    test('hey DJ prefix', () {
      final r = parseAddressed('hey DJ open chrome');
      expect(r.addressed, isTrue);
      expect(r.query, 'open chrome');
      expect(r.wakeWord, 'hey');
    });
    test('okay / hello / hi prefixes', () {
      expect(parseAddressed('okay DJ, list files').wakeWord, 'okay');
      expect(parseAddressed('hello DJ find notes').wakeWord, 'hello');
      expect(parseAddressed('hi DJ, help').wakeWord, 'hi');
      expect(parseAddressed('ok DJ go').wakeWord, 'ok');
    });
    test('no name -> not addressed', () {
      final r = parseAddressed('find my notes');
      expect(r.addressed, isFalse);
      expect(r.query, 'find my notes');
      expect(r.wakeWord, isNull);
    });
    test('case-insensitive', () {
      expect(parseAddressed('dj find notes').addressed, isTrue);
      expect(parseAddressed('Hey Dj, go').query, 'go');
    });
    test('rolling transcript window', () {
      final rt = RollingTranscript(maxSegments: 3, windowMs: 1000);
      rt.add('hello world', 1000);
      rt.add('DJ, find notes', 1500);
      rt.add('something else', 1800);
      expect(rt.findAddressed(1900)?.query, 'find notes');
      expect(rt.recent(1900), 'hello world DJ, find notes something else');
      // After the window passes, old segments drop off.
      expect(rt.recent(5000), isEmpty);
      expect(rt.findAddressed(5000), isNull);
      // Max segments cap.
      final rt2 = RollingTranscript(maxSegments: 2, windowMs: 30000);
      rt2.add('one', 100);
      rt2.add('two', 200);
      rt2.add('three', 300);
      expect(rt2.recent(300), 'two three');
    });
    test('routeTask never assumes a model', () {
      expect(routeTask(kind: 'classify', modelUp: false), 'core-rules');
      expect(routeTask(kind: 'answer', modelUp: false), 'core-rules');
      expect(routeTask(kind: 'classify', modelUp: true), 'fast-judge');
      expect(routeTask(kind: 'command', modelUp: true), 'fast-judge');
      expect(routeTask(kind: 'answer', modelUp: true), 'chat-model');
      expect(routeTask(kind: 'dictate', modelUp: true), 'chat-model');
    });
    test('diaryLine format', () {
      expect(
          diaryLine(const DiaryEntry(at: '2026-11-25', kind: 'note', text: 'hello')),
          '- 2026-11-25 [note] hello');
    });
  });

  group('summarize scoring', () {
    test('empty file', () {
      final r = summarizeText('', 'notes.txt');
      expect(r.summary,
          'That file looks empty, so there is nothing to summarize.');
      expect(r.usedFirstLines, isTrue);
    });
    test('five or fewer sentences -> all, first lines', () {
      final r = summarizeText(
          'One sentence here. Two sentences here now. Three is here too.',
          'notes.txt');
      expect(r.usedFirstLines, isTrue);
      expect(r.summary, contains('One sentence here.'));
    });
    test('picks top 5 by score, re-ordered by position', () {
      final text = [
        'Short.',
        'The Virun pitch describes travel and tourism across India with local guides and homestays for every traveller.',
        'Tiny one.',
        'Virun pitch travel tourism guides homestays India local travel tourism guides homestays India local.',
        'Another short line here.',
        'The Virun pitch covers pricing, routes, guides, homestays, tourism, travel, India, and local experiences for travellers.',
        'Yet another short line here now.',
        'Virun is a travel platform for tourism in India with guides and homestays and local experiences for travellers.',
      ].join(' ');
      final r = summarizeText(text, 'virun-pitch.txt');
      expect(r.usedFirstLines, isFalse);
      final lines = r.summary.split('\n');
      expect(lines.length, 5);
      expect(lines.every((l) => l.startsWith('• ')), isTrue);
      // Short sentences (<4 words) score -100 and are excluded.
      expect(r.summary.contains('Short.'), isFalse);
      expect(r.summary.contains('Tiny one.'), isFalse);
    });
    test('>60 word sentence scores -50 and is excluded', () {
      final long = '${List.filled(70, 'word').join(' ')}.';
      final good = List.generate(
          7,
          (i) =>
              'Sentence number $i about the Virun pitch and travel tourism guides here.').join(' ');
      final r = summarizeText('$long $good', 'virun.txt');
      expect(r.summary.contains('word word'), isFalse);
      expect(r.usedFirstLines, isFalse);
    });
  });

  group('organize range parsing', () {
    test('parseOrganizeRangeText', () {
      expect(parseOrganizeRangeText('organize all downloads'), 'all');
      expect(parseOrganizeRangeText('organize everything'), 'all');
      expect(parseOrganizeRangeText("organize yesterday's downloads"), 'yesterday');
      expect(parseOrganizeRangeText('organize last 3 days'), 'last 3 days');
      expect(parseOrganizeRangeText('organize past 1 day'), 'last 1 day');
      expect(parseOrganizeRangeText('organize this week'), 'last 7 days');
      expect(parseOrganizeRangeText('organize last week'), 'last 7 days');
      expect(parseOrganizeRangeText('organize today'), 'today');
      expect(parseOrganizeRangeText('organize downloads'), isNull);
    });
    test('parseOrganizeRange', () {
      expect(parseOrganizeRange('all') is OrganizeRangeAll, isTrue);
      expect(parseOrganizeRange('yesterday') is OrganizeRangeYesterday, isTrue);
      final last3 = parseOrganizeRange('last 3 days');
      expect(last3, isA<OrganizeRangeLastDays>());
      expect((last3 as OrganizeRangeLastDays).days, 3);
      expect(parseOrganizeRange('this week'),
          isA<OrganizeRangeLastDays>());
      expect((parseOrganizeRange('this week') as OrganizeRangeLastDays).days, 7);
      expect(parseOrganizeRange('today') is OrganizeRangeToday, isTrue);
      expect(parseOrganizeRange('downloads'), isNull);
    });
    test('rangeLabel', () {
      expect(rangeLabel(const OrganizeRangeToday()), 'today');
      expect(rangeLabel(const OrganizeRangeYesterday()), 'yesterday');
      expect(rangeLabel(const OrganizeRangeLastDays(days: 3)), 'the last 3 days');
      expect(rangeLabel(const OrganizeRangeLastDays(days: 1)), 'the last 1 day');
      expect(rangeLabel(const OrganizeRangeAll()), 'all files');
    });
    test('destinationFolder keyword beats type', () {
      expect(destinationFolder('sapss-report.pdf'), ['Hackathons', 'SAPSS-Vishwakarma']);
      expect(destinationFolder('my-virun-pitch.docx'), ['Hackathons', 'Virun-Travel']);
      expect(destinationFolder('assignment-1.pdf'), ['College']);
      expect(destinationFolder('my-credentials.txt'), ['_Private-DoNotShare']);
      expect(destinationFolder('file.env'), ['_Private-DoNotShare']);
      expect(destinationFolder('whatsapp image 2026.jpg'), ['Images', 'WhatsApp']);
      expect(destinationFolder('screenshot 2026-01-01.png'), ['Images']);
      expect(destinationFolder('movie.mp4'), ['Movies']);
      expect(destinationFolder('song.mp3'), ['Music']);
      expect(destinationFolder('report.pdf'), ['Documents']);
      expect(destinationFolder('data.xlsx'), ['Spreadsheets']);
      expect(destinationFolder('slides.pptx'), ['Presentations']);
      expect(destinationFolder('script.py'), ['Code']);
      expect(destinationFolder('archive.zip'), ['Archives']);
      expect(destinationFolder('weirdfile.xyz'), ['_Review']);
    });
    test('organize plan + apply moves only on apply', () {
      final tmp = Directory.systemTemp.createTempSync('dj-org-');
      try {
        final dl = Directory('${tmp.path}/Downloads')..createSync();
        File('${dl.path}/sapss-report.pdf').writeAsStringSync('x');
        File('${dl.path}/movie.mp4').writeAsStringSync('x');
        File('${dl.path}/_Organizer_Log.csv').writeAsStringSync('x');
        File('${dl.path}/organize-downloads.ps1').writeAsStringSync('x');
        final svc = OrganizeService();
        final plan = svc.plan(dl.path, const OrganizeRangeAll());
        expect(plan.map((m) => m.name).toList(),
            ['movie.mp4', 'sapss-report.pdf']);
        // Plan moves nothing.
        expect(File('${dl.path}/movie.mp4').existsSync(), isTrue);
        final result = svc.apply(plan, dl.path);
        expect(result.errors, isEmpty);
        expect(result.moved.length, 2);
        expect(File('${dl.path}/movie.mp4').existsSync(), isFalse);
        expect(File('${dl.path}/Movies/movie.mp4').existsSync(), isTrue);
        expect(
            File('${dl.path}/Hackathons/SAPSS-Vishwakarma/sapss-report.pdf')
                .existsSync(),
            isTrue);
        expect(File(result.logPath).existsSync(), isTrue);
        // The log file already existed (pre-created to test the skip
        // rule), so no header is written — rows are appended.
        final log = File(result.logPath).readAsStringSync();
        expect(log, contains('"movie.mp4"'));
        expect(log, contains('Movies/movie.mp4')); 
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
    test('freePath never overwrites', () {
      final tmp = Directory.systemTemp.createTempSync('dj-free-');
      try {
        File('${tmp.path}/a.txt').writeAsStringSync('x');
        expect(freePath(tmp.path, 'a.txt'), '${tmp.path}/a-1.txt');
        File('${tmp.path}/a-1.txt').writeAsStringSync('x');
        expect(freePath(tmp.path, 'a.txt'), '${tmp.path}/a-2.txt');
        expect(freePath(tmp.path, 'b.txt'), '${tmp.path}/b.txt');
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
    test('lastDays includes exactly N days ago', () {
      final tmp = Directory.systemTemp.createTempSync('dj-range-');
      try {
        final dl = Directory('${tmp.path}/Downloads')..createSync();
        final now = DateTime.now();
        final f = File('${dl.path}/old.txt')..writeAsStringSync('x');
        f.setLastModifiedSync(now.subtract(const Duration(days: 3)));
        final svc = OrganizeService();
        expect(svc.plan(dl.path, const OrganizeRangeLastDays(days: 3), now).length, 1);
        expect(svc.plan(dl.path, const OrganizeRangeLastDays(days: 2), now).length, 0);
        expect(svc.plan(dl.path, const OrganizeRangeToday(), now).length, 0);
        expect(svc.plan(dl.path, const OrganizeRangeYesterday(), now).length, 0);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });

  group('config', () {
    test('defaultFolders: Downloads, Desktop, Documents, Pictures, home fallback', () {
      final tmp = Directory.systemTemp.createTempSync('dj-home-');
      try {
        final folders = defaultFolders(tmp.path);
        expect(folders.length, 5);
        expect(folders[0].path, endsWith('Downloads'));
        expect(folders[2].path, endsWith('Documents'));
        expect(folders[3].path, endsWith('Pictures'));
        // No Antigravity folder -> 5th entry is home itself.
        expect(folders[4].path, tmp.path);
        expect(folders.every((f) => f.enabled), isTrue);
        // OneDrive Desktop preferred when present.
        Directory('${tmp.path}/OneDrive/Desktop').createSync(recursive: true);
        expect(findDesktop(tmp.path), endsWith('Desktop'));
        expect(findDesktop(tmp.path), contains('OneDrive'));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
    test('corrupt config -> defaults, never crash; save/load roundtrip', () {
      final tmp = Directory.systemTemp.createTempSync('dj-config-');
      try {
        final repo = ConfigRepository(dataDir: tmp.path);
        expect(repo.load().folders.length, 5);
        File(repo.configPath).writeAsStringSync('{not json');
        expect(repo.load().folders.length, 5);
        final cfg = AppConfig(
          folders: [
            FolderEntry(path: '${tmp.path}/Docs', enabled: true),
            FolderEntry(path: '${tmp.path}/Off', enabled: false),
          ],
          startAtLogin: true,
          privacySensitivity: 0.42,
          privacyDetectShoulderSurfers: false,
          privacyStartOnLaunch: true,
        );
        repo.save(cfg);
        final loaded = repo.load();
        expect(loaded.folders.length, 2);
        expect(loaded.startAtLogin, isTrue);
        expect(loaded.privacySensitivity, 0.42);
        expect(loaded.privacyDetectShoulderSurfers, isFalse);
        expect(loaded.privacyStartOnLaunch, isTrue);
        expect(File(repo.configPath).readAsStringSync(), contains('\n  "folders"'));
        expect(enabledFolders(loaded), isEmpty); // neither dir exists
        Directory('${tmp.path}/Docs').createSync();
        expect(enabledFolders(loaded), ['${tmp.path}/Docs']);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });

  group('hashing', () {
    test('known SHA-256 / SHA-1 vectors', () {
      // sha256('abc')
      expect(sha256Bytes(Uint8List.fromList([97, 98, 99])),
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      // sha256 of a file's contents, streamed in 1 MB chunks.
      final tmp = Directory.systemTemp.createTempSync('dj-hash-');
      try {
        final f = File('${tmp.path}/abc.txt')..writeAsStringSync('abc');
        expect(sha256File(f.path),
            'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
        expect(sha256File('${tmp.path}/missing.txt'), isNull);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
    test('sha1Hex abc', () {
      expect(sha1Hex('abc'), 'a9993e364706816aba3e25717850c26c9cd0d89d');
      expect(fileId('/some/path/file.txt').length, 16);
    });
    test('humanSize', () {
      expect(humanSize(2450), '2.4 KB');
      expect(humanSize(500), '500 B');
      expect(humanSize(1024 * 1024), '1.0 MB');
    });
  });
}
