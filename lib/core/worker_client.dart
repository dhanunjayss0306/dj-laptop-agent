// WorkerClient — the app's client for the DJ Cloudflare Worker proxy.
//
// The app NEVER holds an AI provider key. All provider calls go through the
// Worker (see worker/src/index.ts); this client only knows the Worker URL.
// The only key-like value here is the optional [WorkerClient.sharedKey]:
// a shared secret the Worker itself checks (header `X-DJ-Key`), never a
// provider key, and it is sent only when it is non-empty.
//
// Behaviour (PORTING-SPEC.md §3.3):
// - chat() streams the reply text (the Worker normalises every provider to
//   OpenAI-style SSE).
// - A 401/403 from the Worker means the cloud key is expired/invalid:
//   throws [CloudKeyExpired]. The capability layer catches that and falls
//   back to Local/Core. It is never retried here.
// - Any other failure throws [WorkerException] with a plain message.
//
// Uses dart:io HttpClient only — no new pub dependency.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Any failure talking to the Worker, with a plain message safe to show.
class WorkerException implements Exception {
  WorkerException(this.message);

  final String message;

  @override
  String toString() => 'WorkerException: $message';
}

/// Thrown when the Worker answers 401/403: the cloud key is expired or
/// invalid. The capability layer catches this and falls back to Local/Core.
class CloudKeyExpired extends WorkerException {
  CloudKeyExpired() : super('cloud key expired');
}

/// Cloud providers the Worker can forward chat to (PORTING-SPEC.md §3.3).
/// gemini, groq and nvidia are the free ones (keys live only as Worker
/// secrets). gemini's default model is multimodal; groq/nvidia defaults
/// are text-only, so a screenshot question with those providers fails
/// with a plain message — use Gemini or OpenAI for screen questions.
enum CloudProvider { openai, openrouter, anthropic, gemini, groq, nvidia }

extension on CloudProvider {
  String get apiName => name;
}

/// One chat message, in the shape the Worker expects.
///
/// Text-only messages send `content` as a plain string (unchanged).
/// A message with [imageBase64] sends `content` as an OpenAI-style
/// parts array: a text part plus an `image_url` part whose URL is a
/// `data:` URL (`data:<mime>;base64,...`). The Worker forwards that
/// shape to OpenAI/OpenRouter/Gemini/Groq/NVIDIA as-is and converts it
/// to Anthropic image blocks for Anthropic. The model must be
/// vision-capable (for example gpt-4o, claude-sonnet-4-5, or
/// gemini-3.8-flash) or the provider rejects it.
class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.content,
    this.imageBase64,
    this.imageMimeType = 'image/png',
  });

  final String role;
  final String content;

  /// Raw image bytes as base64 (no `data:` prefix). Null = text only.
  final String? imageBase64;

  /// MIME type of [imageBase64], for the `data:` URL. PNG screenshots
  /// are the default; use 'image/jpeg' for JPEG bytes.
  final String imageMimeType;

  Map<String, Object> toJson() {
    if (imageBase64 == null || imageBase64!.isEmpty) {
      return {'role': role, 'content': content};
    }
    return {
      'role': role,
      'content': [
        {'type': 'text', 'text': content},
        {
          'type': 'image_url',
          'image_url': {
            'url': 'data:$imageMimeType;base64,$imageBase64',
          },
        },
      ],
    };
  }
}

class WorkerClient {
  /// [baseUrl] is the Worker URL, e.g.
  /// `https://dj-proxy.<subdomain>.workers.dev` (no trailing slash needed).
  /// [httpClient] is injectable for tests; pass nothing in the app.
  /// [sharedKey] is the optional shared secret the Worker checks as the
  /// `X-DJ-Key` header on every call. Empty (the default) sends no
  /// header; the Worker only enforces a key when its DJ_SHARED_KEY
  /// secret is set, so an empty key keeps the app working.
  WorkerClient(
    String baseUrl, {
    HttpClient? httpClient,
    this.timeout = const Duration(seconds: 10),
    String sharedKey = '',
  })  : baseUrl = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
        sharedKey = sharedKey.trim(),
        _client = httpClient ?? HttpClient();

  final String baseUrl;
  final Duration timeout;

  /// Optional Worker shared key, sent as `X-DJ-Key` when non-empty.
  final String sharedKey;
  final HttpClient _client;

  /// Stream the chat reply text for [provider]/[model]/[messages].
  ///
  /// Yields each text delta as it arrives. Throws [CloudKeyExpired] on
  /// 401/403 and [WorkerException] on any other failure.
  Stream<String> chat({
    required CloudProvider provider,
    required String model,
    required List<ChatMessage> messages,
  }) async* {
    final request = await _open('POST', '/chat');
    request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    request.write(jsonEncode({
      'provider': provider.apiName,
      'model': model,
      'messages': messages.map((m) => m.toJson()).toList(),
    }));
    final response = await request.close().timeout(timeout);
    await _throwIfError(response);

    await for (final line
        in response.transform(utf8.decoder).transform(const LineSplitter())) {
      if (!line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data.isEmpty || data == '[DONE]') continue;
      final content = _sseContent(data);
      if (content != null && content.isNotEmpty) yield content;
    }
  }

  /// Text-to-speech through the Worker. Yields raw audio bytes (MP3).
  /// [voiceId] overrides the Worker's default voice when given.
  Stream<List<int>> tts({required String text, String? voiceId}) async* {
    final request = await _open('POST', '/tts');
    request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    request.write(jsonEncode({
      'text': text,
      if (voiceId != null) 'voiceId': voiceId,
    }));
    final response = await request.close().timeout(timeout);
    await _throwIfError(response);
    yield* response;
  }

  /// A short-lived AssemblyAI realtime token for streaming transcription.
  /// This is a temporary token, never the raw AssemblyAI key.
  Future<String> transcribeToken() async {
    final request = await _open('GET', '/transcribe-token');
    final response = await request.close().timeout(timeout);
    await _throwIfError(response);
    final body = await _readJson(response);
    final token = body['token'];
    if (token is! String || token.isEmpty) {
      throw WorkerException('transcribe token missing');
    }
    return token;
  }

  /// True when the Worker answers /health with `{ok: true}`.
  /// Never throws: any failure means "not up".
  Future<bool> health() async {
    try {
      final request = await _open('GET', '/health');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) return false;
      final body = await _readJson(response);
      return body['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Close the underlying HttpClient when the app shuts down.
  void close() => _client.close(force: true);

  /// Every Worker call goes through here, so the shared key (when set)
  /// is sent on chat, tts, transcribe-token and health alike, and
  /// nothing is sent when no key is configured.
  Future<HttpClientRequest> _open(String method, String path) async {
    final request =
        await _client.openUrl(method, Uri.parse('$baseUrl$path')).timeout(timeout);
    if (sharedKey.isNotEmpty) {
      request.headers.set('X-DJ-Key', sharedKey);
    }
    return request;
  }

  /// Throws [CloudKeyExpired] on 401/403, [WorkerException] otherwise.
  /// Consumes the body so the connection can be reused.
  Future<void> _throwIfError(HttpClientResponse response) async {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw CloudKeyExpired();
    }
    throw WorkerException(_plainMessage(body, response.statusCode));
  }

  Future<Map<String, dynamic>> _readJson(HttpClientResponse response) async {
    final body = await response.transform(utf8.decoder).join();
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // Fall through to the plain-message error below.
    }
    throw WorkerException(_plainMessage(body, response.statusCode));
  }

  /// Pull the Worker's plain `message` out of an error body, if present.
  /// Never surfaces raw provider output.
  String _plainMessage(String body, int status) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final message = decoded['message'];
        if (message is String && message.isNotEmpty) return message;
      }
    } catch (_) {
      // Not JSON: fall through.
    }
    return 'worker error ($status)';
  }

  /// Extract the text delta from one OpenAI-style SSE `data:` payload.
  /// Returns null for malformed chunks (they are skipped, not fatal).
  static String? _sseContent(String data) {
    try {
      final decoded = jsonDecode(data);
      if (decoded is! Map<String, dynamic>) return null;
      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty) return null;
      final first = choices.first;
      if (first is! Map<String, dynamic>) return null;
      final delta = first['delta'];
      if (delta is! Map<String, dynamic>) return null;
      final content = delta['content'];
      return content is String ? content : null;
    } catch (_) {
      return null;
    }
  }
}
