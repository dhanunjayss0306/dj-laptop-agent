import 'dart:io';

import 'package:dj/core/config.dart';
import 'package:dj/core/hashing.dart';
import 'package:dj/core/models.dart';
import 'package:dj/core/security.dart';
import 'package:dj/features/wake_word.dart';
import 'package:dj/services/duplicate_service.dart';
import 'package:dj/ui/app_state.dart';
import 'package:dj/ui/screen_qa_flow.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WakeWord extractWakeCommand', () {
    test('extracts command from Hey DJ variants', () {
      final a = extractWakeCommand('Hey DJ open Chrome');
      expect(a.matched, isTrue);
      expect(a.command, 'open Chrome');

      final b = extractWakeCommand('Hey, D.J.! please find my Virun pitch');
      expect(b.matched, isTrue);
      expect(b.command, 'find my Virun pitch');

      final c = extractWakeCommand('OK deejay: organize yesterday');
      expect(c.matched, isTrue);
      expect(c.command, 'organize yesterday');
    });

    test('matches bare wake phrase with empty command', () {
      final bare = extractWakeCommand('Hey DJ');
      expect(bare.matched, isTrue);
      expect(bare.command, '');
    });

    test('ignores normal sentences without wake word', () {
      final none = extractWakeCommand('what is on my screen right now');
      expect(none.matched, isFalse);
      expect(none.command, '');
    });
  });

  group('classifyVoiceCommand', () {
    test('routes instant actions and agent tasks locally without vision', () {
      expect(classifyVoiceCommand('open chrome'), VoiceRouteKind.chat);
      expect(classifyVoiceCommand('find my Virun pitch'), VoiceRouteKind.chat);
      expect(classifyVoiceCommand('organize yesterday'), VoiceRouteKind.chat);
      expect(classifyVoiceCommand('find duplicates'), VoiceRouteKind.chat);
      expect(classifyVoiceCommand('agent open notepad'), VoiceRouteKind.agent);
      expect(
        classifyVoiceCommand('dj agent click export'),
        VoiceRouteKind.agent,
      );
    });

    test('routes screen questions to ScreenQA', () {
      expect(
        classifyVoiceCommand('What is this error on my screen?'),
        VoiceRouteKind.screen,
      );
      expect(
        classifyVoiceCommand('Where do I click to export?'),
        VoiceRouteKind.screen,
      );
    });
  });

  group('security guards', () {
    test('WorkspaceGuard rejects NUL bytes and symlink escapes', () {
      final tmp = Directory.systemTemp.createTempSync('dj_sec_test_');
      try {
        final ws = Directory('${tmp.path}${Platform.pathSeparator}ws')
          ..createSync();
        final outside = File('${tmp.path}${Platform.pathSeparator}secret.txt')
          ..writeAsStringSync('top-secret');
        final guard = WorkspaceGuard([ws.path]);

        expect(guard.resolve('${ws.path}\x00evil.txt'), isNull);
        expect(guard.resolve(outside.path), isNull);
        expect(
          guard.resolve('${ws.path}${Platform.pathSeparator}new_note.txt'),
          isNotNull,
        );

        try {
          final link = Link('${ws.path}${Platform.pathSeparator}escape_link')
            ..createSync(outside.path);
          expect(guard.resolve(link.path), isNull);
        } catch (_) {
          // Symlink creation may require elevation on older Windows hosts.
        }
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('isSensitivePath blocks secrets and configs', () {
      expect(isSensitivePath('/home/user/dj_cloud.json'), isTrue);
      expect(isSensitivePath('C:\\Users\\dj\\dj_config.json'), isTrue);
      expect(isSensitivePath('/work/app/.env.production'), isTrue);
      expect(isSensitivePath('/home/user/.ssh/id_ed25519'), isTrue);
      expect(isSensitivePath('/home/user/certs/server.pem'), isTrue);
      expect(isSensitivePath('/home/user/Documents/notes.md'), isFalse);
    });
  });

  group('async duplicate hashing & quickFileSignatureAsync', () {
    test('finds identical large files accurately without blocking', () async {
      final tmp = Directory.systemTemp.createTempSync('dj_dup_async_');
      try {
        final f1 = File('${tmp.path}${Platform.pathSeparator}a.bin');
        final f2 = File('${tmp.path}${Platform.pathSeparator}b.bin');
        final f3 = File('${tmp.path}${Platform.pathSeparator}c.bin');

        final payload = List<int>.filled(40000, 65);
        final diffTail = List<int>.from(payload)..[39999] = 66;
        f1.writeAsBytesSync(payload);
        f2.writeAsBytesSync(payload);
        f3.writeAsBytesSync(diffTail);

        expect(
          await quickFileSignatureAsync(f1.path),
          await quickFileSignatureAsync(f2.path),
        );
        expect(
          await quickFileSignatureAsync(f1.path),
          isNot(await quickFileSignatureAsync(f3.path)),
        );
        expect(await sha256FileAsync(f1.path), await sha256FileAsync(f2.path));

        final groups = await DuplicateService().find([tmp.path]);
        expect(groups.length, 1);
        expect(groups.first.files.length, 2);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });

  group('hotkey presets and config persistence', () {
    test('AppConfig preserves speakScreenAnswers and hotkeyPreset', () {
      final tmp = Directory.systemTemp.createTempSync('dj_cfg_test_');
      try {
        final repo = ConfigRepository(dataDir: tmp.path);
        final saved = AppConfig(
          folders: const [],
          speakScreenAnswers: true,
          hotkeyPreset: 'alt_space',
        );
        repo.save(saved);
        final loaded = repo.load();
        expect(loaded.speakScreenAnswers, isTrue);
        expect(loaded.hotkeyPreset, 'alt_space');
        expect(DjAppState.hotkeyForPreset('alt_space').label, 'Alt + Space');
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
}
