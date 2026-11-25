// GitHub integration — list repos, search code, read a file, via the
// GitHub REST API (api.github.com).
//
// Auth is a personal access token (PAT) the user creates and pastes:
//   1. GitHub > Settings > Developer settings > Personal access tokens
//      > Tokens (classic) > Generate new token.
//   2. Give it a note (e.g. "DJ laptop"), pick an expiry, and tick
//      the `repo` scope. The token NEEDS `repo` scope to list private
//      repos and read private files; without it only public repos work.
//   3. Paste the token into DJ (saved by [saveToken] below).
//
// The token is stored locally ONLY, in dj_config.json under
// integrations.github.token. It is sent only to api.github.com
// (Authorization: Bearer <token>), never anywhere else, never logged.
// DJ never creates, edits, commits, or deletes anything on GitHub —
// read-only in this build.

import 'dart:convert';
import 'dart:io';

import 'google_oauth.dart';
import 'integration.dart';

/// One repo from the GitHub API. Pure parsing.
class GitHubRepo {
  const GitHubRepo({
    required this.name,
    required this.fullName,
    required this.url,
    this.description,
    this.isPrivate = false,
  });
  final String name;
  final String fullName;
  final String url;
  final String? description;
  final bool isPrivate;

  factory GitHubRepo.fromJson(Map<String, dynamic> j) => GitHubRepo(
        name: (j['name'] ?? '') as String,
        fullName: (j['full_name'] ?? '') as String,
        url: (j['html_url'] ?? '') as String,
        description: j['description'] as String?,
        isPrivate: j['private'] == true,
      );

  @override
  String toString() => '• $fullName${isPrivate ? ' (private)' : ''} — $url';
}

class GitHubException implements Exception {
  const GitHubException(this.message);
  final String message;
  @override
  String toString() => 'GitHubException: $message';
}

class GitHubIntegration extends Integration {
  GitHubIntegration({
    required String dataDir,
    HttpClient? httpClient,
  })  : _store = IntegrationTokenStore(
          '$dataDir${Platform.pathSeparator}dj_config.json',
        ),
        _client = httpClient ?? HttpClient();

  final IntegrationTokenStore _store;
  final HttpClient _client;

  static const String _apiBase = 'https://api.github.com';

  String? get _token {
    final raw = _store.section('github')['token'];
    return raw is String && raw.isNotEmpty ? raw : null;
  }

  @override
  String get id => 'github';

  @override
  String get name => 'GitHub';

  @override
  String get description =>
      'List your repos, search code, read a file. Read-only; needs a personal access token with repo scope.';

  @override
  bool get isConnected => _token != null;

  /// True when a token is already stored. First-time connect: the
  /// user pastes their token via [saveToken].
  @override
  Future<bool> connect() async => isConnected;

  /// Save the user's personal access token (local only, never sent
  /// anywhere except api.github.com).
  void saveToken(String token) {
    final section = _store.section('github');
    section['token'] = token.trim();
    _store.saveSection('github', section);
  }

  @override
  Future<void> disconnect() async => _store.clearSection('github');

  @override
  List<IntegrationAction> get actions => [
        IntegrationAction(
          name: 'listRepos',
          description: 'List your repos (newest updated first, 20).',
          run: (_) async {
            final body = await _get(
              '$_apiBase/user/repos?per_page=20&sort=updated',
            );
            if (body is! List) return 'Unexpected reply from GitHub.';
            final repos = body
                .whereType<Map<String, dynamic>>()
                .map(GitHubRepo.fromJson)
                .toList();
            if (repos.isEmpty) return 'No repos found for this account.';
            return repos.map((r) => r.toString()).join('\n');
          },
        ),
        IntegrationAction(
          name: 'searchCode',
          description: 'Search code in your repos, e.g. {query: "AgentLoop"}.',
          run: (args) async {
            final query = (args['query'] ?? '') as String;
            if (query.trim().isEmpty) {
              return 'Give me words to search for in code.';
            }
            final body = await _get(
              '$_apiBase/search/code?q=${Uri.encodeQueryComponent(query)}&per_page=10',
            );
            if (body is! Map<String, dynamic>) {
              return 'Unexpected reply from GitHub.';
            }
            final items = body['items'];
            if (items is! List || items.isEmpty) {
              return 'No code found for "$query".';
            }
            final lines = <String>[];
            for (final item in items.take(10)) {
              if (item is! Map<String, dynamic>) continue;
              final repo = item['repository'];
              final repoName =
                  repo is Map<String, dynamic> ? repo['full_name'] : '?';
              lines.add('• ${item['path']} in $repoName');
            }
            return lines.join('\n');
          },
        ),
        IntegrationAction(
          name: 'readFile',
          description:
              'Read a file, e.g. {repo: "owner/name", path: "README.md"}.',
          run: (args) async {
            final repo = (args['repo'] ?? '') as String;
            final path = (args['path'] ?? '') as String;
            if (repo.trim().isEmpty || path.trim().isEmpty) {
              return 'Give me a repo ("owner/name") and a file path.';
            }
            final body = await _get(
              '$_apiBase/repos/$repo/contents/${Uri.encodeComponent(path)}',
              acceptRaw: true,
            );
            if (body is String) return body;
            return 'Could not read $path in $repo.';
          },
        ),
      ];

  /// GET a GitHub API URL with the stored token. Returns decoded JSON,
  /// or the raw text when [acceptRaw] (used for file contents).
  Future<Object> _get(String url, {bool acceptRaw = false}) async {
    final token = _token;
    if (token == null) {
      throw const GitHubException('Not connected yet — paste a token first.');
    }
    final request = await _client.getUrl(Uri.parse(url));
    request.headers.set('Authorization', 'Bearer $token');
    request.headers.set('Accept',
        acceptRaw ? 'application/vnd.github.raw' : 'application/vnd.github+json');
    request.headers.set('X-GitHub-Api-Version', '2022-11-28');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw GitHubException(
        'GitHub refused the token (${response.statusCode}). '
        'Check the token and its repo scope, then reconnect.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw GitHubException(
        'GitHub request failed (${response.statusCode}).',
      );
    }
    if (acceptRaw) return body;
    return jsonDecode(body);
  }

  void close() => _client.close(force: true);
}
