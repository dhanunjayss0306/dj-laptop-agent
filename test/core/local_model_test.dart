// Tests for local-model answering (lib/core/local_model.dart and
// the Cloud -> Local -> Core fallback in ChatService).
//
// Uses hand-written fakes for dart:io HttpClient — no new
// dependency, no real server. Verifies:
// - Ollama / LM Studio model lists are parsed;
// - detect() tries Ollama first, then LM Studio, and picks
//   qwen3.5:9b when it is installed;
// - a local answer says which model answered, on the laptop;
// - when no local model is running, DJ falls to Core with a plain
//   message — never hangs, never a made-up answer.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dj/core/local_model.dart';
import 'package:dj/core/models.dart';
import 'package:dj/core/worker_client.dart';
import 'package:dj/services/chat_service.dart';
import 'package:dj/services/index_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/fakes.dart';

class _FakeHeaders implements HttpHeaders {
  final Map<String, List<String>> values = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = [value.toString()];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse(this.statusCode, List<int> bytes) : _bytes = bytes;

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

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.response, {this.onClose});

  final HttpClientResponse response;

  /// Called with the full written body when the caller closes the
  /// request (after writing). Deterministic: no polling.
  final void Function(String body)? onClose;
  final StringBuffer bodyBuffer = StringBuffer();

  @override
  final HttpHeaders headers = _FakeHeaders();

  @override
  void write(Object? object) => bodyBuffer.write(object);

  @override
  Future<HttpClientResponse> close() async {
    onClose?.call(bodyBuffer.toString());
    return response;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// A fake HttpClient that answers by URL substring. A URL with no
/// matching route throws SocketException, like a refused localhost
/// connection (Ollama / LM Studio not running).
class _RoutingFakeHttpClient implements HttpClient {
  _RoutingFakeHttpClient(this.routes);

  /// URL substring -> (status, body).
  final Map<String, (int, String)> routes;
  final List<Uri> requested = [];
  final List<String> requestBodies = [];

  @override
  Future<HttpClientRequest> getUrl(Uri url) => _request(url);

  @override
  Future<HttpClientRequest> postUrl(Uri url) => _request(url);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _request(url);

  Future<HttpClientRequest> _request(Uri url) async {
    requested.add(url);
    for (final entry in routes.entries) {
      if (url.toString().contains(entry.key)) {
        final index = requestBodies.length;
        requestBodies.add('');
        return _FakeRequest(
          _FakeResponse(entry.value.$1, utf8.encode(entry.value.$2)),
          onClose: (body) => requestBodies[index] = body,
        );
      }
    }
    throw const SocketException('connection refused');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  group('LocalModelClient lists models', () {
    test('Ollama tags list parses model names', () async {
      final fake = _RoutingFakeHttpClient({
        '11434/api/tags': (
          200,
          '{"models":[{"name":"qwen3.5:9b","size":1},{"name":"qwen2.5-coder:7b","size":1}]}'
        ),
      });
      final client = LocalModelClient(httpClient: fake);
      expect(await client.listOllamaModels(),
          ['qwen3.5:9b', 'qwen2.5-coder:7b']);
      expect(fake.requested.single.toString(),
          contains('127.0.0.1:11434/api/tags'));
    });

    test('LM Studio models list parses ids', () async {
      final fake = _RoutingFakeHttpClient({
        '1234/v1/models': (
          200,
          '{"data":[{"id":"qwen2.5-7b-instruct"},{"id":"other-model"}]}'
        ),
      });
      final client = LocalModelClient(httpClient: fake);
      expect(await client.listLmStudioModels(),
          ['qwen2.5-7b-instruct', 'other-model']);
    });

    test('a bad server answer is a plain LocalModelException', () async {
      final fake = _RoutingFakeHttpClient({
        '11434/api/tags': (500, 'not json at all'),
      });
      final client = LocalModelClient(httpClient: fake);
      await expectLater(
        client.listOllamaModels(),
        throwsA(isA<LocalModelException>()),
      );
    });
  });

  group('LocalModelClient detect', () {
    test('picks Ollama and qwen3.5:9b when installed', () async {
      final fake = _RoutingFakeHttpClient({
        '11434/api/tags': (
          200,
          '{"models":[{"name":"qwen2.5-coder:7b"},{"name":"qwen3.5:9b"}]}'
        ),
      });
      final client = LocalModelClient(httpClient: fake);
      final choice = await client.detect();
      expect(choice, isNotNull);
      expect(choice!.kind, 'ollama');
      expect(choice.model, 'qwen3.5:9b');
    });

    test('falls to LM Studio when Ollama is down', () async {
      final fake = _RoutingFakeHttpClient({
        '1234/v1/models': (200, '{"data":[{"id":"lmstudio-model"}]}'),
      });
      final client = LocalModelClient(httpClient: fake);
      final choice = await client.detect();
      expect(choice, isNotNull);
      expect(choice!.kind, 'lmstudio');
      expect(choice.model, 'lmstudio-model');
    });

    test('returns null when nothing is up', () async {
      final fake = _RoutingFakeHttpClient({});
      final client = LocalModelClient(httpClient: fake);
      expect(await client.detect(), isNull);
    });

    test('a picked model that is not installed uses the best available',
        () async {
      final fake = _RoutingFakeHttpClient({
        '11434/api/tags': (200, '{"models":[{"name":"qwen2.5-coder:7b"}]}'),
        '1234/v1/models': (200, '{"data":[{"id":"lmstudio-model"}]}'),
      });
      final client = LocalModelClient(httpClient: fake);
      final choice = await client.detect(
        preferredKind: 'ollama',
        preferredModel: 'qwen3.5:9b',
      );
      // qwen3.5:9b is not in Ollama, so DJ uses the best model that
      // is there and says which one answered — better than no answer.
      expect(choice, isNotNull);
      expect(choice!.kind, 'ollama');
      expect(choice.model, 'qwen2.5-coder:7b');
    });

    test('a picked LM Studio server is tried first', () async {
      final fake = _RoutingFakeHttpClient({
        '11434/api/tags': (200, '{"models":[{"name":"qwen3.5:9b"}]}'),
        '1234/v1/models': (200, '{"data":[{"id":"lmstudio-model"}]}'),
      });
      final client = LocalModelClient(httpClient: fake);
      final choice = await client.detect(preferredKind: 'lmstudio');
      expect(choice, isNotNull);
      expect(choice!.kind, 'lmstudio');
      expect(fake.requested.first.toString(), contains('1234/v1/models'));
    });
  });

  group('LocalModelClient chat', () {
    test('Ollama chat posts the model and returns the reply', () async {
      final fake = _RoutingFakeHttpClient({
        '11434/api/chat': (
          200,
          '{"message":{"role":"assistant","content":"The pitch costs Rs 499."},"done":true}'
        ),
      });
      final client = LocalModelClient(httpClient: fake);
      final reply = await client.chat(
        choice: const LocalModelChoice(kind: 'ollama', model: 'qwen3.5:9b'),
        messages: const [
          ChatMessage(role: 'user', content: 'what does it cost?'),
        ],
      );
      expect(reply, 'The pitch costs Rs 499.');
      expect(fake.requestBodies.join(), contains('"model":"qwen3.5:9b"'));
      expect(fake.requestBodies.join(), contains('what does it cost?'));
    });

    test('LM Studio chat returns the first choice', () async {
      final fake = _RoutingFakeHttpClient({
        '1234/v1/chat/completions': (
          200,
          '{"choices":[{"message":{"role":"assistant","content":"LM Studio says hi."}}]}'
        ),
      });
      final client = LocalModelClient(httpClient: fake);
      final reply = await client.chat(
        choice:
            const LocalModelChoice(kind: 'lmstudio', model: 'lmstudio-model'),
        messages: const [
          ChatMessage(role: 'user', content: 'hi'),
        ],
      );
      expect(reply, 'LM Studio says hi.');
    });

    test('a 500 from the model is a plain LocalModelException', () async {
      final fake = _RoutingFakeHttpClient({
        '11434/api/chat': (500, 'boom'),
      });
      final client = LocalModelClient(httpClient: fake);
      await expectLater(
        client.chat(
          choice: const LocalModelChoice(kind: 'ollama', model: 'qwen3.5:9b'),
          messages: const [ChatMessage(role: 'user', content: 'hi')],
        ),
        throwsA(isA<LocalModelException>()),
      );
    });
  });

  group('ChatService local fallback', () {
    late Directory tmp;
    late IndexService indexer;
    late ChatService chat;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('dj-local-');
      final dataDir = Directory('${tmp.path}/dj_data')..createSync();
      final docs = Directory('${tmp.path}/Docs')..createSync();
      File('${docs.path}/virun-pitch.txt').writeAsStringSync(
          'Virun is a travel and tourism platform for India with local guides. Pricing is Rs 499 per trip.');
      indexer = IndexService(
          dataDir: dataDir.path, embedder: NotStartedEmbedder());
      await indexer.build(['${tmp.path}/Docs']);
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    ChatService buildChat(LocalModelClient? local,
        {bool preferLocal = false, WorkerClient? cloud}) {
      return ChatService(
        indexer: indexer,
        getFolders: () => ['${tmp.path}/Docs'],
        systemOps: FakeSystemOps(),
        local: local,
        preferLocal: preferLocal,
        cloud: cloud,
      );
    }

    test('Ollama unreachable falls to Core with a plain message',
        () async {
      chat = buildChat(LocalModelClient(httpClient: _RoutingFakeHttpClient({})));
      final r = await chat
          .handle('what does my Virun pitch say about pricing?');
      expect(r.kind, 'search');
      final s = r as ChatResponseSearch;
      expect(s.text, contains('No AI answered'));
      expect(s.text, contains('ollama serve'));
      expect(s.results.first.name, 'virun-pitch.txt');
    });

    test('a local answer says which model answered', () async {
      final fake = _RoutingFakeHttpClient({
        '11434/api/tags': (200, '{"models":[{"name":"qwen3.5:9b"}]}'),
        '11434/api/chat': (
          200,
          '{"message":{"role":"assistant","content":"Pricing is Rs 499 per trip."},"done":true}'
        ),
      });
      chat = buildChat(LocalModelClient(httpClient: fake));
      final r = await chat
          .handle('what does my Virun pitch say about pricing?');
      expect(r.kind, 'search');
      final s = r as ChatResponseSearch;
      expect(s.text, contains('Pricing is Rs 499 per trip.'));
      expect(s.text, contains('answered by qwen3.5:9b on your laptop'));
      expect(s.results.first.name, 'virun-pitch.txt');
    });

    test('preferLocal answers locally even when the cloud is set',
        () async {
      final fake = _RoutingFakeHttpClient({
        '11434/api/tags': (200, '{"models":[{"name":"qwen3.5:9b"}]}'),
        '11434/api/chat': (
          200,
          '{"message":{"role":"assistant","content":"Local answer here."},"done":true}'
        ),
        'workers.dev/chat': (
          200,
          'data: {"choices":[{"delta":{"content":"Cloud answer here."}}]}\n\ndata: [DONE]\n'
        ),
      });
      final cloud = WorkerClient(
        'https://dj-proxy.test.workers.dev',
        httpClient: fake,
      );
      chat = buildChat(
        LocalModelClient(httpClient: fake),
        preferLocal: true,
        cloud: cloud,
      );
      final r = await chat
          .handle('what does my Virun pitch say about pricing?');
      final s = r as ChatResponseSearch;
      expect(s.text, contains('Local answer here.'));
      expect(s.text, contains('answered by qwen3.5:9b on your laptop'));
      expect(s.text, isNot(contains('Cloud answer here.')));
    });

    test('cloud first by default when the cloud is set', () async {
      final fake = _RoutingFakeHttpClient({
        '11434/api/tags': (200, '{"models":[{"name":"qwen3.5:9b"}]}'),
        '11434/api/chat': (
          200,
          '{"message":{"role":"assistant","content":"Local answer here."},"done":true}'
        ),
        'workers.dev/chat': (
          200,
          'data: {"choices":[{"delta":{"content":"Cloud answer here."}}]}\n\ndata: [DONE]\n'
        ),
      });
      final cloud = WorkerClient(
        'https://dj-proxy.test.workers.dev',
        httpClient: fake,
      );
      chat = buildChat(
        LocalModelClient(httpClient: fake),
        preferLocal: false,
        cloud: cloud,
      );
      final r = await chat
          .handle('what does my Virun pitch say about pricing?');
      final s = r as ChatResponseSearch;
      expect(s.text, contains('Cloud answer here.'));
      expect(s.text, isNot(contains('Local answer here.')));
    });
  });
}
