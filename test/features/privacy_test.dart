// Privacy tests: deleteAllData wipes the data dir (and only with a
// confirmed choice), clearScreenHistory is a no-op, and no screenshot
// bytes are ever written to disk.
//
// The no-screenshot test runs a real ScreenQA.ask against mocked
// channels with a fake PNG, then audits the temp data dir: no image
// file may appear. ScreenQA takes no path and writes nothing — the
// test pins that behaviour so a later change cannot silently add a
// screenshot write.

import 'dart:io';

import 'package:dj/features/privacy.dart';
import 'package:dj/features/screen_qa.dart';
import 'package:dj/platform/cursor_channel.dart';
import 'package:dj/platform/screen_channel.dart';
import 'package:dj/platform/voice_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const screenChannel = MethodChannel('com.dhanunjay.dj/screen');
  const cursorChannel = MethodChannel('com.dhanunjay.dj/cursor');
  const voiceChannel = MethodChannel('com.dhanunjay.dj/voice');

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dj_privacy_test_');
    messenger.setMockMethodCallHandler(screenChannel, (call) async {
      // A fake 1x1 PNG (bytes only — never written anywhere).
      return <String, dynamic>{
        'ok': true,
        'png': Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]),
        'width': 1920,
        'height': 1080,
        'monitors': <dynamic>[],
      };
    });
    messenger.setMockMethodCallHandler(cursorChannel, (call) async {
      return <String, dynamic>{'ok': true};
    });
    messenger.setMockMethodCallHandler(voiceChannel, (call) async {
      return <String, dynamic>{'ok': true};
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(screenChannel, null);
    messenger.setMockMethodCallHandler(cursorChannel, null);
    messenger.setMockMethodCallHandler(voiceChannel, null);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('no screenshot bytes are written to any file', () async {
    final dataDir = Directory('${tmp.path}/dj_data')..createSync();
    final qa = ScreenQA(
      screen: ScreenChannel(channel: screenChannel),
      cursor: CursorChannel(channel: cursorChannel),
      voice: VoiceChannel(channel: voiceChannel),
      modelUp: () => false, // Core-only fallback path
    );
    final answer = await qa.ask('what is on the screen?');
    expect(answer.fallbackUsed, isTrue);

    // Audit the whole temp tree: no image file anywhere.
    final files = tmp
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => f.path)
        .toList();
    expect(
      files.where(
        (p) =>
            p.endsWith('.png') ||
            p.endsWith('.jpg') ||
            p.endsWith('.jpeg'),
      ),
      isEmpty,
    );
    expect(PrivacyService.screenshotsAreMemoryOnly, isTrue);
    expect(dataDir.existsSync(), isTrue);
  });

  test('clearScreenHistory is a documented no-op', () {
    final privacy = PrivacyService(dataDir: '${tmp.path}/dj_data');
    expect(
      privacy.clearScreenHistory(),
      contains('never stores screenshots'),
    );
  });

  test('deleteAllData wipes the data dir and recreates it empty', () async {
    final dataDir = Directory('${tmp.path}/dj_data');
    dataDir.createSync(recursive: true);
    File('${dataDir.path}/dj_config.json').writeAsStringSync('{}');
    File('${dataDir.path}/MEMORY.md').writeAsStringSync('notes');
    File('${dataDir.path}/routines.json').writeAsStringSync('[]');
    Directory('${dataDir.path}/memory').createSync();

    final privacy = PrivacyService(dataDir: dataDir.path);
    await privacy.deleteAllData(confirmed: true);

    expect(dataDir.existsSync(), isTrue);
    expect(dataDir.listSync().toList(), isEmpty);
  });

  test('deleteAllData without confirmation throws and deletes nothing', () async {
    final dataDir = Directory('${tmp.path}/dj_data');
    dataDir.createSync(recursive: true);
    final keep = File('${dataDir.path}/dj_config.json')
      ..writeAsStringSync('{}');

    final privacy = PrivacyService(dataDir: dataDir.path);
    await expectLater(
      privacy.deleteAllData(confirmed: false),
      throwsA(isA<StateError>()),
    );
    expect(keep.existsSync(), isTrue);
  });

  test('deleteAllData refuses a path that is not a dj_data folder', () async {
    final notData = Directory('${tmp.path}/something_else');
    notData.createSync(recursive: true);
    File('${notData.path}/keep.txt').writeAsStringSync('keep me');
    final privacy = PrivacyService(dataDir: notData.path);
    await expectLater(
      privacy.deleteAllData(confirmed: true),
      throwsA(isA<StateError>()),
    );
    expect(File('${notData.path}/keep.txt').existsSync(), isTrue);
  });
}
