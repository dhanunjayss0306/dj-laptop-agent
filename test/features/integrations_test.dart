// Integrations tests: registry order, deep-link URL builders,
// Gmail/Drive parsers, GitHub token storage, browser helpers.
// Google network calls are never made here — OAuth token exchange
// and API GETs are covered by the pure parsers + the token store.

import 'dart:convert';
import 'dart:io';

import 'package:dj/features/integrations/integrations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dj_integrations_test_');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('registry', () {
    test('default order is the user-set order', () {
      final registry = defaultRegistry(
        dataDir: tmp.path,
        systemOps: FakeSystemOps(),
      );
      expect(
        registry.list().map((i) => i.id).toList(),
        [
          'whatsapp',
          'gmail',
          'drive',
          'github',
          'instagram',
          'browsers',
          'local_apps',
        ],
      );
    });

    test('get returns each integration; unknown id returns null', () {
      final registry = defaultRegistry(
        dataDir: tmp.path,
        systemOps: FakeSystemOps(),
      );
      expect(registry.get('gmail')?.name, 'Gmail');
      expect(registry.get('nope'), isNull);
    });

    test('registering the same id twice keeps one entry', () {
      final registry = defaultRegistry(
        dataDir: tmp.path,
        systemOps: FakeSystemOps(),
      );
      registry.register(WhatsAppIntegration(systemOps: FakeSystemOps()));
      expect(
        registry.list().where((i) => i.id == 'whatsapp').length,
        1,
      );
    });
  });

  group('WhatsApp (deep links only)', () {
    test('chat URL strips spaces/+ and encodes the text', () {
      expect(
        whatsAppChatUrl('+91 89199 13605', 'hi there'),
        'https://wa.me/918919913605?text=hi+there',
      );
      expect(whatsAppChatUrl('918919913605'), 'https://wa.me/918919913605');
    });

    test('share URL encodes the text', () {
      expect(
        whatsAppShareUrl('hello world'),
        'https://wa.me/?text=hello+world',
      );
    });

    test('is always connected (no login needed) and refuses no number', () async {
      final wa = WhatsAppIntegration(systemOps: FakeSystemOps());
      expect(wa.isConnected, isTrue);
      expect(await wa.runAction('openChat', {'number': ''}),
          contains('phone number'));
    });
  });

  group('Gmail (pure parsers)', () {
    test('parseGmailMessage reads headers and decodes the body', () {
      final bodyText = base64Url.encode(utf8.encode('Hello from DJ.'));
      final message = {
        'id': 'msg1',
        'snippet': 'Hello from DJ.',
        'payload': {
          'headers': [
            {'name': 'Subject', 'value': 'Test mail'},
            {'name': 'From', 'value': 'a@example.com'},
            {'name': 'Date', 'value': 'Tue, 25 Nov 2026'},
          ],
          'mimeType': 'multipart/alternative',
          'parts': [
            {
              'mimeType': 'text/plain',
              'body': {'data': bodyText},
            },
          ],
        },
      };
      final parsed = parseGmailMessage(message);
      expect(parsed.id, 'msg1');
      expect(parsed.subject, 'Test mail');
      expect(parsed.from, 'a@example.com');
      expect(parsed.body, 'Hello from DJ.');
    });

    test('isConnected is false until tokens are stored', () {
      final gmail = GmailIntegration(dataDir: tmp.path);
      expect(gmail.isConnected, isFalse);
    });

    test('a disconnected action refuses politely', () async {
      final gmail = GmailIntegration(dataDir: tmp.path);
      expect(
        await gmail.runAction('searchMail', {'query': 'test'}),
        contains('not connected yet'),
      );
    });
  });

  group('Drive (pure parsers)', () {
    test('parseDriveFiles reads the file list', () {
      final files = parseDriveFiles({
        'files': [
          {
            'id': 'f1',
            'name': 'Virun pitch.pdf',
            'mimeType': 'application/pdf',
            'modifiedTime': '2026-11-20T00:00:00Z',
            'size': 1234,
          },
        ],
      });
      expect(files.length, 1);
      expect(files.first.name, 'Virun pitch.pdf');
      expect(files.first.size, 1234);
    });

    test('isConnected is false until tokens are stored', () {
      expect(DriveIntegration(dataDir: tmp.path).isConnected, isFalse);
    });
  });

  group('GitHub (token, local only)', () {
    test('saveToken connects; disconnect forgets; token stays local', () {
      final gh = GitHubIntegration(dataDir: tmp.path);
      expect(gh.isConnected, isFalse);
      gh.saveToken('ghp_test_token_123');
      expect(gh.isConnected, isTrue);

      // The token is in dj_config.json under integrations.github…
      final config = jsonDecode(
        File('${tmp.path}/dj_config.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final section =
          (config['integrations'] as Map)['github'] as Map<String, dynamic>;
      expect(section['token'], 'ghp_test_token_123');
      // …and nowhere else in the file.
      final raw = File('${tmp.path}/dj_config.json').readAsStringSync();
      expect('ghp_test_token_123'.allMatches(raw).length, 1);

      gh.disconnect();
      expect(gh.isConnected, isFalse);
    });

    test('a disconnected action refuses politely', () async {
      final gh = GitHubIntegration(dataDir: tmp.path);
      expect(
        await gh.runAction('listRepos'),
        contains('not connected yet'),
      );
    });
  });

  group('Instagram (deep links only)', () {
    test('profile deep link and web URL strip the @', () {
      expect(
        instagramProfileDeepLink('@dhanunjayss1122'),
        'instagram://user?username=dhanunjayss1122',
      );
      expect(
        instagramProfileUrl('dhanunjayss1122'),
        'https://instagram.com/dhanunjayss1122',
      );
    });

    test('is always connected (no login needed)', () {
      expect(
        InstagramIntegration(systemOps: FakeSystemOps()).isConnected,
        isTrue,
      );
    });
  });

  group('Browsers', () {
    test('normaliseUrl adds https:// to a bare domain', () {
      expect(normaliseUrl('example.com'), 'https://example.com');
      expect(normaliseUrl('https://example.com'), 'https://example.com');
      expect(normaliseUrl('http://localhost:5173'), 'http://localhost:5173');
    });

    test('findBrowser knows chrome and opera, not an unknown name', () {
      expect(findBrowser('chrome')?.name, 'chrome');
      expect(findBrowser('Opera')?.name, 'opera');
      expect(findBrowser('netscape'), isNull);
    });

    test('unknown browser returns a plain message', () async {
      final b = BrowsersIntegration(systemOps: FakeSystemOps());
      expect(
        await b.runAction('openUrl', {'browser': 'netscape', 'url': 'x.com'}),
        contains("don't know a browser"),
      );
    });
  });

  group('Local apps', () {
    test('openApp delegates to the launcher message', () async {
      final apps = LocalAppsIntegration(systemOps: FakeSystemOps());
      expect(apps.isConnected, isTrue);
      expect(
        await apps.runAction('openApp', {'name': 'notepad'}),
        contains('notepad'),
      );
    });

    test('listApps on Android without the native method says so plainly',
        () async {
      // No mock handler is set for 'com.dhanunjay.dj/system' here, so
      // the invoke throws MissingPluginException — exactly the case
      // where the native listApps method is missing.
      final apps = LocalAppsIntegration(systemOps: FakeSystemOps());
      expect(await apps.listApps(), 'Listing apps is not available on Android yet.');
    });
  });
}
