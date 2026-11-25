// Browsers integration — launch a URL in the browser the user picks.
//
// HONEST SCOPE: this opens a URL in Chrome, Opera, Edge or the
// default browser. It does NOT read tabs, history, or page contents.
// Reading tabs needs a browser extension, which is NOT in this build.
//
// How it works:
//   * Windows: launch the browser exe with the URL as an argument,
//     via SystemOps.openApp (exe + args). Chrome and Opera are looked
//     up by their usual install paths, then on PATH.
//   * Android: launch the browser app by package name via
//     SystemOps.openApp. The system channel IGNORES args, so the URL
//     cannot be passed on Android yet — the browser opens, and DJ
//     shows the URL for the user. Passing a URL needs a native
//     'openUrl' method on the Android system channel, which does not
//     exist yet (listed in heyclicky_features.md).
//   * openDJ: opens DJ itself in the browser — the local app URL the
//     user runs DJ from (defaults to http://localhost:5173, the Vite
//     dev server from the Electron app; the UI can pass the real URL).

import 'dart:io';

import '../../services/system_ops.dart';
import 'integration.dart';

/// Known browsers: display name -> Windows exe candidates (in order)
/// and Android package name. Pure data — easy to extend.
class BrowserChoice {
  const BrowserChoice({
    required this.name,
    required this.windowsExes,
    required this.androidPackage,
  });
  final String name;
  final List<String> windowsExes;
  final String androidPackage;
}

const List<BrowserChoice> knownBrowsers = [
  BrowserChoice(
    name: 'chrome',
    windowsExes: [
      'chrome.exe',
      r'C:\Program Files\Google\Chrome\Application\chrome.exe',
      r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
    ],
    androidPackage: 'com.android.chrome',
  ),
  BrowserChoice(
    name: 'opera',
    windowsExes: [
      'opera.exe',
      r'C:\Program Files\Opera\opera.exe',
      r'C:\Program Files (x86)\Opera\opera.exe',
    ],
    androidPackage: 'com.opera.browser',
  ),
  BrowserChoice(
    name: 'edge',
    windowsExes: [
      'msedge.exe',
      r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    ],
    androidPackage: 'com.microsoft.emmx',
  ),
  BrowserChoice(
    name: 'firefox',
    windowsExes: [
      'firefox.exe',
      r'C:\Program Files\Mozilla Firefox\firefox.exe',
    ],
    androidPackage: 'org.mozilla.firefox',
  ),
];

BrowserChoice? findBrowser(String name) {
  final low = name.trim().toLowerCase();
  for (final b in knownBrowsers) {
    if (b.name == low) return b;
  }
  return null;
}

/// Normalise a URL: add https:// when the user typed a bare domain.
String normaliseUrl(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return trimmed;
  if (trimmed.contains('://')) return trimmed;
  return 'https://$trimmed';
}

class BrowsersIntegration extends Integration {
  BrowsersIntegration({required SystemOps systemOps}) : _ops = systemOps;

  final SystemOps _ops;

  @override
  String get id => 'browsers';

  @override
  String get name => 'Browsers';

  @override
  String get description =>
      'Open a link in Chrome, Opera, Edge or Firefox. No tab reading.';

  /// Always connected: launching a browser needs no login.
  @override
  bool get isConnected => true;

  @override
  Future<bool> connect() async => true;

  @override
  Future<void> disconnect() async {}

  @override
  List<IntegrationAction> get actions => [
        IntegrationAction(
          name: 'openUrl',
          description:
              'Open a URL in a browser, e.g. {browser: "chrome", url: "example.com"}.',
          needsConnection: false,
          run: (args) async {
            final browserName = (args['browser'] ?? 'chrome') as String;
            final url = normaliseUrl((args['url'] ?? '') as String);
            if (url.isEmpty) return 'Give me a URL to open.';
            return openUrlIn(browserName, url);
          },
        ),
        IntegrationAction(
          name: 'openDJ',
          description: 'Open DJ in the browser, e.g. {url: "http://localhost:5173"}.',
          needsConnection: false,
          run: (args) async {
            final url = (args['url'] ?? 'http://localhost:5173') as String;
            final browserName = (args['browser'] ?? 'chrome') as String;
            return openUrlIn(browserName, normaliseUrl(url));
          },
        ),
      ];

  /// Open [url] in the named browser. Pure logic, channel calls only
  /// through [_ops] so tests can fake it.
  Future<String> openUrlIn(String browserName, String url) async {
    final browser = findBrowser(browserName);
    if (browser == null) {
      return "I don't know a browser called '$browserName'. "
          'Try chrome, opera, edge or firefox.';
    }
    if (Platform.isWindows) {
      final exe = _resolveWindowsExe(browser.windowsExes);
      if (exe == null) {
        return "I could not find ${browser.name} on this laptop. "
            'Open it once yourself, then try again.';
      }
      final result = await _ops.openApp(exe, [url]);
      return result.ok
          ? 'Opened $url in ${browser.name}.'
          : result.message;
    }
    // Android: the system channel ignores launch args, so the URL
    // cannot be passed to the browser yet. Open the browser app and
    // show the URL. (Needs a native 'openUrl' method — not built yet.)
    final result = await _ops.openApp(browser.androidPackage, []);
    if (result.ok) {
      return 'Opened ${browser.name}. I cannot pass the link on Android yet — open this yourself: $url';
    }
    return 'I could not open ${browser.name} on this phone. Link: $url';
  }

  /// First exe candidate that exists (absolute path) or is on PATH.
  String? _resolveWindowsExe(List<String> candidates) {
    for (final c in candidates) {
      if (_isAbsolute(c)) {
        try {
          if (File(c).statSync().type == FileSystemEntityType.file) {
            return c;
          }
        } catch (_) {}
      } else {
        final onPath = _findOnPath(c);
        if (onPath != null) return onPath;
      }
    }
    return null;
  }

  String? _findOnPath(String exe) {
    final pathExt = Platform.environment['PATHEXT'] ?? '.EXE';
    final dirs = (Platform.environment['PATH'] ?? '').split(';');
    for (final dir in dirs) {
      if (dir.isEmpty) continue;
      for (final ext in ['', ...pathExt.split(';')]) {
        final cand = '$dir\\$exe$ext';
        try {
          if (File(cand).statSync().type == FileSystemEntityType.file) {
            return cand;
          }
        } catch (_) {}
      }
    }
    return null;
  }
}

bool _isAbsolute(String p) =>
    RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p) ||
    p.startsWith(Platform.pathSeparator);
