// Gmail integration — search mail + read a message, via the Gmail
// REST API (read-only scope).
//
// Auth is OAuth2 with the user's own Google Cloud client (see
// google_oauth.dart for the exact setup steps). Tokens live locally in
// dj_config.json under integrations.gmail and are refreshed
// automatically. No key is ever sent anywhere except to Google.
//
// Scope: gmail.readonly — DJ can read mail, never send, delete, or
// change labels. (Sending is deliberately out of scope: DJ drafts,
// the user presses send.)

import 'dart:convert';
import 'dart:io';

import 'google_oauth.dart';
import 'integration.dart';

/// One message from a Gmail list/search reply.
class GmailMessageSummary {
  const GmailMessageSummary({
    required this.id,
    required this.subject,
    required this.from,
    required this.date,
    required this.snippet,
    required this.body,
  });
  final String id;
  final String subject;
  final String from;
  final String date;
  final String snippet;
  final String body;

  Map<String, dynamic> toJson() => {
        'id': id,
        'subject': subject,
        'from': from,
        'date': date,
        'snippet': snippet,
        'body': body,
      };
}

/// Header lookup in a Gmail message payload. Pure function.
String gmailHeader(Map<String, dynamic> message, String name) {
  final payload = message['payload'];
  if (payload is! Map<String, dynamic>) return '';
  final headers = payload['headers'];
  if (headers is! List) return '';
  for (final h in headers) {
    if (h is Map<String, dynamic> &&
        (h['name'] as String?)?.toLowerCase() == name.toLowerCase()) {
      return (h['value'] ?? '') as String;
    }
  }
  return '';
}

/// Plain-text body out of a Gmail message payload (full format).
/// Walks parts for a text/plain part; decodes base64url. Pure function.
String gmailBodyText(Map<String, dynamic> message) {
  final payload = message['payload'];
  if (payload is! Map<String, dynamic>) return '';
  String? decodePart(Map<String, dynamic> part) {
    final mime = (part['mimeType'] ?? '') as String;
    final body = part['body'];
    if (mime == 'text/plain' && body is Map<String, dynamic>) {
      final data = body['data'];
      if (data is String && data.isNotEmpty) {
        return _decodeBase64Url(data);
      }
    }
    return null;
  }

  final direct = decodePart(payload);
  if (direct != null) return direct;
  final parts = payload['parts'];
  if (parts is List) {
    for (final part in parts) {
      if (part is Map<String, dynamic>) {
        final text = decodePart(part);
        if (text != null) return text;
        final nested = part['parts'];
        if (nested is List) {
          for (final sub in nested) {
            if (sub is Map<String, dynamic>) {
              final text = decodePart(sub);
              if (text != null) return text;
            }
          }
        }
      }
    }
  }
  return '';
}

String _decodeBase64Url(String data) {
  try {
    final normalised = data.replaceAll('-', '+').replaceAll('_', '/');
    final padded = normalised.padRight(
      normalised.length + (4 - normalised.length % 4) % 4,
      '=',
    );
    return utf8.decode(base64.decode(padded));
  } catch (_) {
    return '';
  }
}

/// Full Gmail message JSON -> [GmailMessageSummary]. Pure function.
GmailMessageSummary parseGmailMessage(Map<String, dynamic> message) {
  return GmailMessageSummary(
    id: (message['id'] ?? '') as String,
    subject: gmailHeader(message, 'Subject'),
    from: gmailHeader(message, 'From'),
    date: gmailHeader(message, 'Date'),
    snippet: (message['snippet'] ?? '') as String,
    body: gmailBodyText(message),
  );
}

class GmailIntegration extends Integration {
  GmailIntegration({
    required String dataDir,
    HttpClient? httpClient,
  }) : _oauth = GoogleOAuthClient(
          id: 'gmail',
          scopes: const ['https://www.googleapis.com/auth/gmail.readonly'],
          store: IntegrationTokenStore(
            '$dataDir${Platform.pathSeparator}dj_config.json',
          ),
          httpClient: httpClient,
        );

  final GoogleOAuthClient _oauth;

  /// Exposed for the UI flow + tests (auth URL, code exchange).
  GoogleOAuthClient get oauth => _oauth;

  @override
  String get id => 'gmail';

  @override
  String get name => 'Gmail';

  @override
  String get description =>
      'Search and read your mail (read-only). Connect with your own Google Cloud OAuth client.';

  @override
  bool get isConnected => _oauth.isConnected;

  /// True only when tokens are already stored. First-time connect:
  /// UI calls [oauth].buildAuthUrl(), the user opens it and pastes
  /// the code back, UI calls [submitAuthCode].
  @override
  Future<bool> connect() async => _oauth.isConnected;

  /// Complete the first-time connect with the code the user pasted.
  Future<bool> submitAuthCode(String code) => _oauth.exchangeCode(code);

  /// Save the user's Google Cloud client ID + secret (one-time setup).
  void saveClientCredentials(GoogleOAuthClientConfig config) =>
      _oauth.saveClientCredentials(config);

  @override
  Future<void> disconnect() async => _oauth.disconnect();

  @override
  List<IntegrationAction> get actions => [
        IntegrationAction(
          name: 'searchMail',
          description: 'Search mail, e.g. {query: "from:Amazon"} (newest 10).',
          run: (args) async {
            final query = (args['query'] ?? '') as String;
            final url =
                'https://gmail.googleapis.com/gmail/v1/users/me/messages'
                '?maxResults=10'
                '${query.trim().isEmpty ? '' : '&q=${Uri.encodeQueryComponent(query)}'}';
            final body = await _oauth.authorizedGet(url);
            final messages = body['messages'];
            if (messages is! List || messages.isEmpty) {
              return 'No mail found${query.trim().isEmpty ? '' : ' for "$query"'}.';
            }
            final lines = <String>[];
            for (final m in messages.take(10)) {
              if (m is! Map<String, dynamic>) continue;
              final full = await _oauth.authorizedGet(
                'https://gmail.googleapis.com/gmail/v1/users/me/messages/${m['id']}?format=full',
              );
              final parsed = parseGmailMessage(full);
              lines.add('• ${parsed.subject} — ${parsed.from} (${parsed.date})');
            }
            return lines.join('\n');
          },
        ),
        IntegrationAction(
          name: 'readMessage',
          description: 'Read one message by id, e.g. {id: "..."}.',
          run: (args) async {
            final id = (args['id'] ?? '') as String;
            if (id.trim().isEmpty) {
              return 'Give me a message id (from searchMail).';
            }
            final body = await _oauth.authorizedGet(
              'https://gmail.googleapis.com/gmail/v1/users/me/messages/$id?format=full',
            );
            final parsed = parseGmailMessage(body);
            final text = parsed.body.isNotEmpty ? parsed.body : parsed.snippet;
            return '${parsed.subject}\nFrom: ${parsed.from}\nDate: ${parsed.date}\n\n$text';
          },
        ),
      ];
}
