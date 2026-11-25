// Instagram integration — deep-link / intent version.
//
// HONEST SCOPE: there is no official API for personal Instagram DMs
// or posting. This integration opens profiles, posts and reels in the
// Instagram app (or the browser when the app is not there) and shares
// a link/text to Instagram. It does NOT read DMs, list followers,
// post photos/reels, or automate anything. Full read/post automation
// needs a business/creator account, a Meta app, and Meta review —
// that is NOT in this build. DJ never claims otherwise.
//
// How it works:
//   * openProfile(handle) -> instagram://user?username=<handle>,
//     falling back to https://instagram.com/<handle>.
//   * openPost(url) -> opens a post/reel link in Instagram.
//   * shareText(text) -> opens Instagram's share flow with the text.
// Deep links are opened through the OS (Windows: start; Android:
// the Instagram app by package name).

import 'dart:io';

import '../../services/system_ops.dart';
import 'integration.dart';

/// instagram:// deep link for a profile. Pure function.
String instagramProfileDeepLink(String handle) {
  final clean = handle.trim().replaceFirst(RegExp(r'^@'), '');
  return 'instagram://user?username=${Uri.encodeQueryComponent(clean)}';
}

/// Web fallback for a profile. Pure function.
String instagramProfileUrl(String handle) {
  final clean = handle.trim().replaceFirst(RegExp(r'^@'), '');
  return 'https://instagram.com/$clean';
}

class InstagramIntegration extends Integration {
  InstagramIntegration({required SystemOps systemOps}) : _ops = systemOps;

  final SystemOps _ops;

  @override
  String get id => 'instagram';

  @override
  String get name => 'Instagram';

  @override
  String get description =>
      'Open profiles, posts and reels in Instagram. No DM reading, no auto-posting.';

  /// Always connected: deep links need no login, no token, no account.
  @override
  bool get isConnected => true;

  @override
  Future<bool> connect() async => true;

  @override
  Future<void> disconnect() async {}

  @override
  List<IntegrationAction> get actions => [
        IntegrationAction(
          name: 'openProfile',
          description: 'Open a profile, e.g. {handle: "dhanunjayss1122"}.',
          needsConnection: false,
          run: (args) async {
            final handle = (args['handle'] ?? '') as String;
            if (handle.trim().isEmpty) {
              return 'Give me an Instagram handle, e.g. dhanunjayss1122.';
            }
            return _openLink(
              instagramProfileDeepLink(handle),
              instagramProfileUrl(handle),
            );
          },
        ),
        IntegrationAction(
          name: 'openPost',
          description: 'Open a post or reel, e.g. {url: "https://.../p/..."}',
          needsConnection: false,
          run: (args) async {
            final url = (args['url'] ?? '') as String;
            if (url.trim().isEmpty) {
              return 'Give me the post or reel link.';
            }
            return _openLink(url, url);
          },
        ),
        IntegrationAction(
          name: 'shareText',
          description: 'Share text/a link to Instagram (you post it).',
          needsConnection: false,
          run: (args) async {
            final text = (args['text'] ?? '') as String;
            if (text.trim().isEmpty) {
              return 'Give me the text or link to share.';
            }
            // No share-to-Instagram URL scheme exists for plain text;
            // open Instagram and hand the user the text to paste.
            final opened = await _openLink(
              'instagram://app',
              'https://instagram.com/',
            );
            return '$opened\nText to share:\n$text';
          },
        ),
        IntegrationAction(
          name: 'openApp',
          description: 'Open Instagram.',
          needsConnection: false,
          run: (_) async {
            final result = await _ops.openApp('instagram.exe', []);
            return result.ok ? 'Opened Instagram.' : result.message;
          },
        ),
      ];

  /// Try the app deep link first, fall back to the web URL.
  /// Windows opens links with `start`; Android opens the Instagram
  /// app by package name (the deep link itself cannot be passed
  /// through the system channel yet — see browsers.dart).
  Future<String> _openLink(String appLink, String webUrl) async {
    if (Platform.isWindows) {
      final result = await _ops.openApp('cmd.exe', ['/c', 'start', '', appLink]);
      if (result.ok) return 'Opened $webUrl';
      final fallback =
          await _ops.openApp('cmd.exe', ['/c', 'start', '', webUrl]);
      return fallback.ok ? 'Opened $webUrl' : fallback.message;
    }
    final result = await _ops.openApp('com.instagram.android', []);
    if (result.ok) {
      return 'Opened Instagram. Link to open: $webUrl';
    }
    return 'I could not open Instagram on this phone. Link: $webUrl';
  }
}
