// WhatsApp integration — deep-link / intent version.
//
// HONEST SCOPE: there is no official API for personal WhatsApp
// accounts. This integration opens WhatsApp (app or web) with a chat
// or a message ready to send — the user presses Send in WhatsApp.
// It does NOT read messages, list chats, or send messages by itself.
// Reading messages and auto-sending need the WhatsApp Business API,
// which is for businesses only (a business number + Meta approval),
// and are NOT in this build. DJ never claims otherwise.
//
// How it works:
//   * openChat(number, text) -> wa.me/<number>?text=... — opens the
//     chat with that number in WhatsApp, with the text pre-filled.
//   * shareText(text) -> opens WhatsApp's share sheet (wa.me share
//     link on Windows; WhatsApp app on Android) with the text.
//   * openApp() -> opens WhatsApp itself.
// Numbers: digits only, with country code, e.g. 918919913605 for an
// Indian number (91 + 10 digits). Spaces, '+' and '-' are stripped.

import 'dart:io';

import '../../services/system_ops.dart';
import 'integration.dart';

/// wa.me link for a chat. Pure function — easy to test.
String whatsAppChatUrl(String number, [String text = '']) {
  final digits = number.replaceAll(RegExp(r'[^0-9]'), '');
  if (text.isEmpty) return 'https://wa.me/$digits';
  return 'https://wa.me/$digits?text=${Uri.encodeQueryComponent(text)}';
}

/// wa.me share link for plain text.
String whatsAppShareUrl(String text) =>
    'https://wa.me/?text=${Uri.encodeQueryComponent(text)}';

class WhatsAppIntegration extends Integration {
  WhatsAppIntegration({required SystemOps systemOps}) : _ops = systemOps;

  final SystemOps _ops;

  @override
  String get id => 'whatsapp';

  @override
  String get name => 'WhatsApp';

  @override
  String get description =>
      'Open a chat or share text to WhatsApp. No message reading, no auto-send.';

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
          name: 'openChat',
          description: 'Open a WhatsApp chat with a number, text pre-filled.',
          needsConnection: false,
          run: (args) async {
            final number = (args['number'] ?? '') as String;
            final text = (args['text'] ?? '') as String;
            if (number.replaceAll(RegExp(r'[^0-9]'), '').isEmpty) {
              return 'Give me a phone number with country code, e.g. 918919913605.';
            }
            return _openUrl(whatsAppChatUrl(number, text));
          },
        ),
        IntegrationAction(
          name: 'shareText',
          description: 'Share text to WhatsApp (you press Send).',
          needsConnection: false,
          run: (args) async {
            final text = (args['text'] ?? '') as String;
            if (text.trim().isEmpty) {
              return 'Give me the text to share.';
            }
            return _openUrl(whatsAppShareUrl(text));
          },
        ),
        IntegrationAction(
          name: 'openApp',
          description: 'Open WhatsApp.',
          needsConnection: false,
          run: (_) async {
            final result = await _ops.openApp('whatsapp.exe', []);
            return result.ok ? 'Opened WhatsApp.' : result.message;
          },
        ),
      ];

  /// Opens a URL in the default browser (Windows: start; Android:
  /// the browser app). On Windows this goes through cmd so the wa.me
  /// link opens in the browser, which hands it to WhatsApp.
  Future<String> _openUrl(String url) async {
    if (Platform.isWindows) {
      final result = await _ops.openApp('cmd.exe', ['/c', 'start', '', url]);
      return result.ok ? 'Opened $url' : result.message;
    }
    // Android: opening a wa.me link needs a browser intent, which the
    // system channel does not expose yet — open WhatsApp itself and
    // tell the user the link. (See browsers.dart for the same gap.)
    final result = await _ops.openApp('com.whatsapp', []);
    if (result.ok) {
      return 'Opened WhatsApp. Link to open: $url';
    }
    return 'I could not open WhatsApp on this phone. Link: $url';
  }
}
