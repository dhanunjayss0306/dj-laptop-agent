// Tests for WorkerClient (lib/core/worker_client.dart).
//
// Uses hand-written fakes for dart:io HttpClient — no new dependency.
// Verifies:
// - a 401/403 from the Worker maps to CloudKeyExpired (the fall-back signal);
// - no API key is ever sent (no auth header, no key field in any body);
// - SSE chat chunks are joined into streamed text;
// - other failures become WorkerException with the Worker's plain message.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dj/core/worker_client.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeHttpHeaders implements HttpHeaders {
  final Map<String, List<String>> values = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = [value.toString()];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class FakeHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  FakeHttpClientResponse(this.statusCode, List<int> bytes) : _bytes = bytes;

  @override
  final int statusCode;
  final List<int> _bytes;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.fromIterable([_bytes]).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class FakeHttpClientRequest implements HttpClientRequest {
  FakeHttpClientRequest(this.response);

  final HttpClientResponse response;
  final StringBuffer bodyBuffer = StringBuffer();

  @override
  final HttpHeaders headers = FakeHttpHeaders();

  @override
  void write(Object? object) => bodyBuffer.write(object);

  @override
  Future<HttpClientResponse> close() async => response;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class FakeHttpClient implements HttpClient {
  FakeHttpClient(this.statusCode, this.body);

  final int statusCode;
  final String body;

  String? lastMethod;
  Uri? lastUri;
  FakeHttpClientRequest? lastRequest;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    lastMethod = method;
    lastUri = url;
    lastRequest = FakeHttpClientRequest(
      FakeHttpClientResponse(statusCode, utf8.encode(body)),
    );
    return lastRequest!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  group('WorkerClient', () {
    test('401 maps to CloudKeyExpired and sends no key', () async {
      final fake = FakeHttpClient(
        401,
        '{"ok":false,"message":"cloud key expired"}',
      );
      final client = WorkerClient(
        'https://dj-proxy.test.workers.dev',
        httpClient: fake,
      );

      await expectLater(
        client
            .chat(
              provider: CloudProvider.openai,
              model: 'gpt-4o-mini',
              messages: const [
                ChatMessage(role: 'user', content: 'hi'),
              ],
            )
            .toList(),
        throwsA(isA<CloudKeyExpired>()),
      );

      expect(fake.lastMethod, 'POST');
      expect(fake.lastUri!.path, '/chat');
      final headers = fake.lastRequest!.headers as FakeHttpHeaders;
      expect(headers.values.containsKey('authorization'), isFalse);
      expect(headers.values.containsKey('x-api-key'), isFalse);
      final body = fake.lastRequest!.bodyBuffer.toString();
      expect(body, contains('"provider":"openai"'));
      expect(body, contains('"model":"gpt-4o-mini"'));
      expect(body.toLowerCase(), isNot(contains('apikey')));
      expect(body.toLowerCase(), isNot(contains('api_key')));
    });

    test('403 also maps to CloudKeyExpired', () async {
      final fake = FakeHttpClient(
        403,
        '{"ok":false,"message":"cloud key expired"}',
      );
      final client = WorkerClient(
        'https://dj-proxy.test.workers.dev',
        httpClient: fake,
      );

      await expectLater(
        client
            .chat(
              provider: CloudProvider.anthropic,
              model: 'claude-sonnet-4-5',
              messages: const [
                ChatMessage(role: 'user', content: 'hi'),
              ],
            )
            .toList(),
        throwsA(isA<CloudKeyExpired>()),
      );
    });

    test('SSE chunks stream back as text', () async {
      const sse =
          'data: {"choices":[{"delta":{"content":"Hello "}}]}\n\n'
          'data: {"choices":[{"delta":{"content":"world"}}]}\n\n'
          'data: [DONE]\n\n';
      final fake = FakeHttpClient(200, sse);
      final client = WorkerClient(
        'https://dj-proxy.test.workers.dev',
        httpClient: fake,
      );

      final text = await client
          .chat(
            provider: CloudProvider.openrouter,
            model: 'openai/gpt-4o-mini',
            messages: const [
              ChatMessage(role: 'user', content: 'hi'),
            ],
          )
          .toList();

      expect(text, ['Hello ', 'world']);
    });

    test('free providers send the right provider and model, no key', () async {
      // provider → (model, expected body fragment)
      const cases = {
        CloudProvider.gemini: 'gemini-3.8-flash',
        CloudProvider.groq: 'openai/gpt-oss-120b',
        CloudProvider.nvidia: 'nvidia/nemotron-3-super-120b-a12b',
      };
      for (final entry in cases.entries) {
        const sse =
            'data: {"choices":[{"delta":{"content":"ok"}}]}\n\n'
            'data: [DONE]\n\n';
        final fake = FakeHttpClient(200, sse);
        final client = WorkerClient(
          'https://dj-proxy.test.workers.dev',
          httpClient: fake,
        );

        final text = await client
            .chat(
              provider: entry.key,
              model: entry.value,
              messages: const [
                ChatMessage(role: 'user', content: 'hi'),
              ],
            )
            .toList();

        expect(text, ['ok']);
        expect(fake.lastMethod, 'POST');
        expect(fake.lastUri!.path, '/chat');
        final headers = fake.lastRequest!.headers as FakeHttpHeaders;
        expect(headers.values.containsKey('authorization'), isFalse);
        expect(headers.values.containsKey('x-api-key'), isFalse);
        final body = fake.lastRequest!.bodyBuffer.toString();
        expect(body, contains('"provider":"${entry.key.name}"'));
        expect(body, contains('"model":"${entry.value}"'));
        expect(body.toLowerCase(), isNot(contains('apikey')));
        expect(body.toLowerCase(), isNot(contains('api_key')));
      }
    });

    test('non-auth failure becomes WorkerException with plain message',
        () async {
      final fake = FakeHttpClient(
        502,
        '{"ok":false,"message":"cloud provider error (500)"}',
      );
      final client = WorkerClient(
        'https://dj-proxy.test.workers.dev',
        httpClient: fake,
      );

      await expectLater(
        client
            .chat(
              provider: CloudProvider.openai,
              model: 'gpt-4o-mini',
              messages: const [
                ChatMessage(role: 'user', content: 'hi'),
              ],
            )
            .toList(),
        throwsA(
          isA<WorkerException>().having(
            (e) => e.message,
            'message',
            'cloud provider error (500)',
          ),
        ),
      );
    });

    test('transcribeToken returns the temporary token, never a key', () async {
      final fake = FakeHttpClient(
        200,
        '{"ok":true,"token":"tmp-abc123","expiresInSeconds":300}',
      );
      final client = WorkerClient(
        'https://dj-proxy.test.workers.dev',
        httpClient: fake,
      );

      expect(await client.transcribeToken(), 'tmp-abc123');
      expect(fake.lastUri!.path, '/transcribe-token');
      final headers = fake.lastRequest!.headers as FakeHttpHeaders;
      expect(headers.values.containsKey('authorization'), isFalse);
    });

    test('health is true on ok, false on failure', () async {
      final up = WorkerClient(
        'https://dj-proxy.test.workers.dev',
        httpClient: FakeHttpClient(200, '{"ok":true}'),
      );
      expect(await up.health(), isTrue);

      final down = WorkerClient(
        'https://dj-proxy.test.workers.dev',
        httpClient: FakeHttpClient(500, '{"ok":false,"message":"nope"}'),
      );
      expect(await down.health(), isFalse);
    });

    test('tts streams audio bytes', () async {
      final fake = FakeHttpClient(200, 'FAKE-MP3-BYTES');
      final client = WorkerClient(
        'https://dj-proxy.test.workers.dev',
        httpClient: fake,
      );

      final bytes = await client
          .tts(text: 'Hi, I am DJ.')
          .fold<List<int>>([], (all, chunk) => all..addAll(chunk));

      expect(utf8.decode(bytes), 'FAKE-MP3-BYTES');
      expect(fake.lastUri!.path, '/tts');
    });

    test('image message serializes as text + image_url parts', () {
      const message = ChatMessage(
        role: 'user',
        content: 'Where is the Save button?',
        imageBase64: 'iVBORw0KGgo=',
      );
      final json = message.toJson();
      expect(json['role'], 'user');
      final content = json['content'] as List;
      expect(content.length, 2);
      expect(content[0], {
        'type': 'text',
        'text': 'Where is the Save button?',
      });
      expect(content[1], {
        'type': 'image_url',
        'image_url': {'url': 'data:image/png;base64,iVBORw0KGgo='},
      });
    });

    test('chat sends the image part and no key', () async {
      const sse =
          'data: {"choices":[{"delta":{"content":"Click Save [POINT:120,300:Save]"}}]}\n\n'
          'data: [DONE]\n\n';
      final fake = FakeHttpClient(200, sse);
      final client = WorkerClient(
        'https://dj-proxy.test.workers.dev',
        httpClient: fake,
      );

      final text = await client
          .chat(
            provider: CloudProvider.openai,
            model: 'gpt-4o',
            messages: const [
              ChatMessage(
                role: 'user',
                content: 'Where is Save?',
                imageBase64: 'iVBORw0KGgo=',
              ),
            ],
          )
          .toList();

      expect(text, ['Click Save [POINT:120,300:Save]']);
      final body = fake.lastRequest!.bodyBuffer.toString();
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final messages = decoded['messages'] as List;
      final content = (messages.first as Map<String, dynamic>)['content'] as List;
      expect(content[1]['type'], 'image_url');
      expect(
        (content[1]['image_url'] as Map<String, dynamic>)['url'],
        'data:image/png;base64,iVBORw0KGgo=',
      );
      expect(body.toLowerCase(), isNot(contains('apikey')));
    });
  });
}
