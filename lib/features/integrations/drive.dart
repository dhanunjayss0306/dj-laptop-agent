// Google Drive integration — search + list files, via the Drive
// REST API (read-only scope).
//
// Auth is OAuth2 with the user's own Google Cloud client (see
// google_oauth.dart for the exact setup steps — the SAME client can
// cover both Gmail and Drive scopes). Tokens live locally in
// dj_config.json under integrations.drive and are refreshed
// automatically. No key is ever sent anywhere except to Google.
//
// Scope: drive.readonly — DJ can list, search and read file metadata,
// never upload, edit, or delete.

import 'dart:io';

import 'google_oauth.dart';
import 'integration.dart';

/// One file from a Drive list/search reply.
class DriveFileSummary {
  const DriveFileSummary({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.modifiedTime,
    this.size,
  });
  final String id;
  final String name;
  final String mimeType;
  final String modifiedTime;
  final int? size;

  factory DriveFileSummary.fromJson(Map<String, dynamic> j) =>
      DriveFileSummary(
        id: (j['id'] ?? '') as String,
        name: (j['name'] ?? '') as String,
        mimeType: (j['mimeType'] ?? '') as String,
        modifiedTime: (j['modifiedTime'] ?? '') as String,
        size: j['size'] is num ? (j['size'] as num).toInt() : null,
      );

  @override
  String toString() => '• $name ($mimeType, modified $modifiedTime)';
}

/// Drive files.list JSON -> summaries. Pure function.
List<DriveFileSummary> parseDriveFiles(Map<String, dynamic> body) {
  final files = body['files'];
  if (files is! List) return const [];
  return files
      .whereType<Map<String, dynamic>>()
      .map(DriveFileSummary.fromJson)
      .toList();
}

class DriveIntegration extends Integration {
  DriveIntegration({
    required String dataDir,
    HttpClient? httpClient,
  }) : _oauth = GoogleOAuthClient(
          id: 'drive',
          scopes: const ['https://www.googleapis.com/auth/drive.readonly'],
          store: IntegrationTokenStore(
            '$dataDir${Platform.pathSeparator}dj_config.json',
          ),
          httpClient: httpClient,
        );

  final GoogleOAuthClient _oauth;

  /// Exposed for the UI flow + tests (auth URL, code exchange).
  GoogleOAuthClient get oauth => _oauth;

  @override
  String get id => 'drive';

  @override
  String get name => 'Google Drive';

  @override
  String get description =>
      'Search and list your Drive files (read-only). Same Google Cloud OAuth client as Gmail.';

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
          name: 'searchFiles',
          description: 'Search Drive by name, e.g. {query: "Virun"}.',
          run: (args) async {
            final query = (args['query'] ?? '') as String;
            if (query.trim().isEmpty) {
              return 'Give me words to search for in file names.';
            }
            final q =
                "name contains '${query.replaceAll("'", "\\'")}' and trashed = false";
            final url =
                'https://www.googleapis.com/drive/v3/files'
                '?q=${Uri.encodeQueryComponent(q)}'
                '&fields=files(id,name,mimeType,modifiedTime,size)'
                '&pageSize=10&orderBy=modifiedTime desc';
            final body = await _oauth.authorizedGet(url);
            final files = parseDriveFiles(body);
            if (files.isEmpty) return 'No Drive files named like "$query".';
            return files.map((f) => f.toString()).join('\n');
          },
        ),
        IntegrationAction(
          name: 'listFiles',
          description: 'List the newest files in Drive (10).',
          run: (_) async {
            const url =
                'https://www.googleapis.com/drive/v3/files'
                '?q=trashed%20%3D%20false'
                '&fields=files(id,name,mimeType,modifiedTime,size)'
                '&pageSize=10&orderBy=modifiedTime desc';
            final body = await _oauth.authorizedGet(url);
            final files = parseDriveFiles(body);
            if (files.isEmpty) return 'No files in Drive.';
            return files.map((f) => f.toString()).join('\n');
          },
        ),
      ];
}
