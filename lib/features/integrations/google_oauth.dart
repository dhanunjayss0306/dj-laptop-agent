// Shared Google OAuth2 for the Gmail + Drive integrations.
//
// HOW THE USER CONNECTS (do this once, in a browser):
//   1. Go to Google Cloud Console (console.cloud.google.com), make a
//      project (any name, e.g. "DJ").
//   2. APIs & Services > Library: enable "Gmail API" and
//      "Google Drive API".
//   3. APIs & Services > Credentials > Create Credentials >
//      "OAuth client ID" > Application type "Desktop app". Give it a
//      name (e.g. "DJ laptop") and create it.
//   4. Copy the Client ID and Client secret it shows.
//   5. In DJ, open the integration and paste the Client ID + secret
//      (saved by [saveClientCredentials] below). DJ asks for them once.
//   6. DJ shows an auth URL. Open it in a browser, sign in with the
//      Google account, allow access, then copy the `code=` value from
//      the browser's address bar and paste it back into DJ.
//   7. DJ swaps the code for tokens and stores them locally.
//
// TOKENS: access + refresh tokens live ONLY in dj_config.json, under
// integrations.<id> (e.g. integrations.gmail.tokens). They are sent
// only to Google (accounts.google.com / oauth2.googleapis.com /
// www.googleapis.com) and never anywhere else, never logged.
// The access token is refreshed automatically when it expires.
// [GoogleOAuthClient.authorizedGet] handles the refresh.
//
// The SAME Google Cloud OAuth client covers both Gmail and Drive:
// the two integrations share the client ID/secret but keep separate
// tokens (different scopes), stored under their own ids.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// OAuth2 tokens for one Google integration.
class GoogleOAuthTokens {
  const GoogleOAuthTokens({
    required this.accessToken,
    this.refreshToken,
    this.expiry,
  });

  final String accessToken;
  final String? refreshToken;

  /// When the access token expires (UTC). Null = unknown, treat as expired.
  final DateTime? expiry;

  bool get expired {
    final e = expiry;
    if (e == null) return true;
    // Refresh a minute early so a slow call never lands on an expired token.
    return DateTime.now().toUtc().isAfter(e.subtract(const Duration(minutes: 1)));
  }

  Map<String, dynamic> toJson() => {
        'accessToken': accessToken,
        if (refreshToken != null) 'refreshToken': refreshToken,
        if (expiry != null) 'expiry': expiry!.toIso8601String(),
      };

  factory GoogleOAuthTokens.fromJson(Map<String, dynamic> j) =>
      GoogleOAuthTokens(
        accessToken: (j['accessToken'] ?? '') as String,
        refreshToken: j['refreshToken'] as String?,
        expiry: j['expiry'] is String
            ? DateTime.tryParse(j['expiry'] as String)
            : null,
      );
}

/// The user's own Google Cloud OAuth client (Desktop app).
class GoogleOAuthClientConfig {
  const GoogleOAuthClientConfig({
    required this.clientId,
    required this.clientSecret,
    this.redirectUri = 'http://localhost',
  });

  final String clientId;
  final String clientSecret;

  /// Loopback redirect. Google shows the code in the address bar
  /// after approval; the user copies the `code=` value into DJ.
  final String redirectUri;

  Map<String, dynamic> toJson() => {
        'clientId': clientId,
        'clientSecret': clientSecret,
        'redirectUri': redirectUri,
      };

  factory GoogleOAuthClientConfig.fromJson(Map<String, dynamic> j) =>
      GoogleOAuthClientConfig(
        clientId: (j['clientId'] ?? '') as String,
        clientSecret: (j['clientSecret'] ?? '') as String,
        redirectUri: (j['redirectUri'] ?? 'http://localhost') as String,
      );
}

/// Reads/writes one integration's section of dj_config.json, keeping
/// every other key (folders, cloud, other integrations) untouched.
/// Corrupt or missing file = empty section, never a crash.
class IntegrationTokenStore {
  IntegrationTokenStore(this.configPath);
  final String configPath;

  Map<String, dynamic> _readAll() {
    try {
      final file = File(configPath);
      if (!file.existsSync()) return {};
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map<String, dynamic>) return Map.of(decoded);
    } catch (_) {}
    return {};
  }

  void _writeAll(Map<String, dynamic> all) {
    final file = File(configPath);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(all),
      encoding: utf8,
    );
  }

  Map<String, dynamic> section(String id) {
    final all = _readAll();
    final integrations = all['integrations'];
    if (integrations is Map<String, dynamic>) {
      final section = integrations[id];
      if (section is Map<String, dynamic>) return Map.of(section);
    }
    return {};
  }

  void saveSection(String id, Map<String, dynamic> value) {
    final all = _readAll();
    final integrations = all['integrations'] is Map
        ? Map<String, dynamic>.from(all['integrations'] as Map)
        : <String, dynamic>{};
    integrations[id] = value;
    all['integrations'] = integrations;
    _writeAll(all);
  }

  void clearSection(String id) {
    final all = _readAll();
    final integrations = all['integrations'];
    if (integrations is Map<String, dynamic>) {
      integrations.remove(id);
      all['integrations'] = integrations;
      _writeAll(all);
    }
  }
}

/// One Google OAuth2 flow (per integration id + scopes).
/// Uses dart:io HttpClient only — no new pub dependency.
class GoogleOAuthClient {
  GoogleOAuthClient({
    required this.id,
    required this.scopes,
    required this.store,
    HttpClient? httpClient,
  }) : _client = httpClient ?? HttpClient();

  /// Integration id: 'gmail' or 'drive'. Also the dj_config.json key.
  final String id;

  /// OAuth scopes, e.g. ['https://www.googleapis.com/auth/gmail.readonly'].
  final List<String> scopes;
  final IntegrationTokenStore store;
  final HttpClient _client;

  static const String authEndpoint =
      'https://accounts.google.com/o/oauth2/v2/auth';
  static const String tokenEndpoint = 'https://oauth2.googleapis.com/token';

  GoogleOAuthClientConfig? get clientConfig {
    final raw = store.section(id)['client'];
    if (raw is Map<String, dynamic>) {
      return GoogleOAuthClientConfig.fromJson(raw);
    }
    return null;
  }

  GoogleOAuthTokens? get tokens {
    final raw = store.section(id)['tokens'];
    if (raw is Map<String, dynamic>) {
      return GoogleOAuthTokens.fromJson(raw);
    }
    return null;
  }

  bool get isConnected {
    final t = tokens;
    return t != null &&
        t.accessToken.isNotEmpty &&
        (t.refreshToken != null || !t.expired);
  }

  /// Save the user's own Google Cloud client ID + secret (step 5).
  void saveClientCredentials(GoogleOAuthClientConfig config) {
    final section = store.section(id);
    section['client'] = config.toJson();
    store.saveSection(id, section);
  }

  /// The URL the user opens in a browser to approve DJ (step 6).
  /// Throws [StateError] when the client credentials are not saved yet.
  String buildAuthUrl() {
    final config = clientConfig;
    if (config == null || config.clientId.isEmpty) {
      throw StateError(
        'No Google Cloud OAuth client saved yet. Create a Desktop-app '
        'OAuth client in Google Cloud Console (see the comment at the '
        'top of google_oauth.dart), then paste its Client ID and secret '
        'into DJ first.',
      );
    }
    final params = {
      'client_id': config.clientId,
      'redirect_uri': config.redirectUri,
      'response_type': 'code',
      'scope': scopes.join(' '),
      'access_type': 'offline',
      'prompt': 'consent',
    };
    final query = params.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return '$authEndpoint?$query';
  }

  /// Swap the pasted code for tokens and store them (step 7).
  /// Returns true on success; throws [GoogleOAuthException] otherwise.
  Future<bool> exchangeCode(String code) async {
    final config = clientConfig;
    if (config == null) {
      throw const GoogleOAuthException(
        'No Google Cloud OAuth client saved yet.',
      );
    }
    final body = await _postForm(tokenEndpoint, {
      'code': code.trim(),
      'client_id': config.clientId,
      'client_secret': config.clientSecret,
      'redirect_uri': config.redirectUri,
      'grant_type': 'authorization_code',
    });
    final tokens = _tokensFromBody(body);
    _saveTokens(tokens);
    return true;
  }

  /// GET a Google API URL with a fresh access token, refreshing first
  /// when the token is expired. Returns the decoded JSON body.
  Future<Map<String, dynamic>> authorizedGet(String url) async {
    var current = tokens;
    if (current == null) {
      throw const GoogleOAuthException('Not connected yet.');
    }
    if (current.expired) {
      current = await refreshTokens();
    }
    final request = await _client.getUrl(Uri.parse(url));
    request.headers.set('Authorization', 'Bearer ${current.accessToken}');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw GoogleOAuthException(
        'Google refused the request (${response.statusCode}). '
        'Reconnect the integration.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw GoogleOAuthException(
        'Google request failed (${response.statusCode}).',
      );
    }
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    throw const GoogleOAuthException('Unexpected reply from Google.');
  }

  /// Refresh the access token with the stored refresh token.
  /// Throws when there is no refresh token (user must reconnect).
  Future<GoogleOAuthTokens> refreshTokens() async {
    final config = clientConfig;
    final current = tokens;
    if (config == null || current?.refreshToken == null) {
      throw const GoogleOAuthException(
        'No refresh token — reconnect the integration.',
      );
    }
    final body = await _postForm(tokenEndpoint, {
      'refresh_token': current!.refreshToken!,
      'client_id': config.clientId,
      'client_secret': config.clientSecret,
      'grant_type': 'refresh_token',
    });
    final fresh = _tokensFromBody(
      body,
      keepRefreshToken: current.refreshToken,
    );
    _saveTokens(fresh);
    return fresh;
  }

  /// Forget this integration's tokens + client credentials.
  void disconnect() => store.clearSection(id);

  GoogleOAuthTokens _tokensFromBody(
    Map<String, dynamic> body, {
    String? keepRefreshToken,
  }) {
    final access = body['access_token'];
    if (access is! String || access.isEmpty) {
      final error = body['error_description'] ?? body['error'] ?? 'unknown error';
      throw GoogleOAuthException('Google token request failed: $error');
    }
    final expiresIn = body['expires_in'];
    final expiry = expiresIn is num
        ? DateTime.now().toUtc().add(Duration(seconds: expiresIn.toInt()))
        : null;
    return GoogleOAuthTokens(
      accessToken: access,
      refreshToken: (body['refresh_token'] as String?) ?? keepRefreshToken,
      expiry: expiry,
    );
  }

  void _saveTokens(GoogleOAuthTokens tokens) {
    final section = store.section(id);
    section['tokens'] = tokens.toJson();
    store.saveSection(id, section);
  }

  Future<Map<String, dynamic>> _postForm(
    String url,
    Map<String, String> fields,
  ) async {
    final request = await _client.postUrl(Uri.parse(url));
    request.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/x-www-form-urlencoded',
    );
    request.write(
      fields.entries
          .map((e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
          .join('&'),
    );
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return decoded;
      }
      final error =
          decoded['error_description'] ?? decoded['error'] ?? 'request failed';
      throw GoogleOAuthException(
        'Google request failed (${response.statusCode}): $error',
      );
    }
    throw GoogleOAuthException(
      'Google request failed (${response.statusCode}).',
    );
  }

  void close() => _client.close(force: true);
}

class GoogleOAuthException implements Exception {
  const GoogleOAuthException(this.message);
  final String message;
  @override
  String toString() => 'GoogleOAuthException: $message';
}
