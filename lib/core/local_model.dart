// Local models — Ollama and LM Studio, on this machine only.
//
// DJ talks to a model server running on the user's own laptop:
// Ollama at http://127.0.0.1:11434 and LM Studio at
// http://127.0.0.1:1234. No key, no account, no cloud. The model
// runs on the user's hardware; only the question and the file
// excerpts are sent, to localhost.
//
// Order is fixed: Ollama first, then LM Studio, then Core. When the
// user picks a server/model in Settings that server is tried first.
// Nothing here ever hangs: every call is bounded by a timeout, and
// every failure is a LocalModelException with a plain message.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'worker_client.dart';

/// Any failure talking to a local model, with a plain message safe
/// to show the user. Never carries raw server output.
class LocalModelException implements Exception {
  LocalModelException(this.message);

  final String message;

  @override
  String toString() => 'LocalModelException: $message';
}

/// Which local server answered, and with which model.
class LocalModelChoice {
  const LocalModelChoice({
    required this.kind,
    required this.model,
    this.models = const [],
  });

  /// 'ollama' | 'lmstudio'.
  final String kind;

  /// The model name to send, for example 'qwen3.5:9b'.
  final String model;

  /// Every model found on that server.
  final List<String> models;
}

class LocalModelClient {
  /// [httpClient] is injectable for tests; pass nothing in the app.
  LocalModelClient({
    HttpClient? httpClient,
    this.probeTimeout = const Duration(seconds: 2),
    this.chatTimeout = const Duration(seconds: 120),
  }) : _client = httpClient ?? HttpClient();

  final HttpClient _client;

  /// How long a probe (list models) may take.
  final Duration probeTimeout;

  /// How long one answer may take. Local models are slow on CPU,
  /// but the call never hangs past this.
  final Duration chatTimeout;

  static const String ollamaBase = 'http://127.0.0.1:11434';
  static const String ollamaTagsUrl = '$ollamaBase/api/tags';
  static const String ollamaChatUrl = '$ollamaBase/api/chat';
  static const String lmStudioBase = 'http://127.0.0.1:1234';
  static const String lmStudioModelsUrl = '$lmStudioBase/v1/models';
  static const String lmStudioChatUrl = '$lmStudioBase/v1/chat/completions';

  /// The model DJ picks when the user did not pick one: qwen3.5:9b
  /// when it is installed, else the first model on the server.
  static const String preferredModelName = 'qwen3.5:9b';

  /// Close the underlying HttpClient when the app shuts down.
  void close() => _client.close(force: true);

  /// Model names installed in Ollama. Throws [LocalModelException]
  /// with a plain message when Ollama is not running or answers
  /// badly.
  Future<List<String>> listOllamaModels() =>
      _listModels(ollamaTagsUrl, _ollamaNames);

  /// Model ids loaded in LM Studio. Throws [LocalModelException]
  /// with a plain message when the LM Studio server is not running
  /// or answers badly.
  Future<List<String>> listLmStudioModels() =>
      _listModels(lmStudioModelsUrl, _lmStudioNames);

  /// Find a local model to answer with. Tries Ollama first, then LM
  /// Studio — unless [preferredKind] names a server, in which case
  /// that server is tried first. [preferredModel] is the model the
  /// user picked in Settings: it is used when it is installed, else
  /// the server's default pick is used. Returns null when no local
  /// model is available. Never throws.
  Future<LocalModelChoice?> detect({
    String? preferredKind,
    String? preferredModel,
  }) async {
    final order = preferredKind == 'lmstudio'
        ? const ['lmstudio', 'ollama']
        : const ['ollama', 'lmstudio'];
    for (final kind in order) {
      List<String> models;
      try {
        models = kind == 'ollama'
            ? await listOllamaModels()
            : await listLmStudioModels();
      } catch (_) {
        continue;
      }
      if (models.isEmpty) continue;
      final model = _pickModel(models, preferredModel);
      return LocalModelChoice(kind: kind, model: model, models: models);
    }
    return null;
  }

  /// Ask the chosen local model a question. [messages] are the
  /// ChatMessage list (system + user, file excerpts as context).
  /// Images are dropped: the local models answer text only.
  /// Returns the reply text. Throws [LocalModelException] with a
  /// plain message on any failure.
  Future<String> chat({
    required LocalModelChoice choice,
    required List<ChatMessage> messages,
  }) async {
    if (choice.kind == 'lmstudio') {
      return _chatLmStudio(choice.model, messages);
    }
    return _chatOllama(choice.model, messages);
  }

  Future<List<String>> _listModels(
    String url,
    List<String> Function(Map<String, dynamic>) parse,
  ) async {
    try {
      final request =
          await _client.getUrl(Uri.parse(url)).timeout(probeTimeout);
      final response = await request.close().timeout(probeTimeout);
      final body =
          await response.transform(utf8.decoder).join().timeout(probeTimeout);
      if (response.statusCode != 200) {
        throw LocalModelException(
            'the local model server answered ${response.statusCode}');
      }
      final data = jsonDecode(body);
      if (data is! Map<String, dynamic>) {
        throw LocalModelException(
            'the local model server gave an unreadable answer');
      }
      return parse(data);
    } on LocalModelException {
      rethrow;
    } on TimeoutException {
      throw LocalModelException('the local model server did not answer');
    } catch (_) {
      throw LocalModelException('the local model server is not running');
    }
  }

  Future<String> _chatOllama(
      String model, List<ChatMessage> messages) async {
    final data = await _postJson(ollamaChatUrl, {
      'model': model,
      'stream': false,
      'messages': _plainMessages(messages),
    });
    final message = data['message'];
    final content = message is Map ? message['content'] : null;
    if (content is String && content.trim().isNotEmpty) {
      return content.trim();
    }
    throw LocalModelException('the local model gave an empty answer');
  }

  Future<String> _chatLmStudio(
      String model, List<ChatMessage> messages) async {
    final data = await _postJson(lmStudioChatUrl, {
      'model': model,
      'stream': false,
      'messages': _plainMessages(messages),
    });
    final choices = data['choices'];
    if (choices is List && choices.isNotEmpty) {
      final first = choices.first;
      final message = first is Map ? first['message'] : null;
      final content = message is Map ? message['content'] : null;
      if (content is String && content.trim().isNotEmpty) {
        return content.trim();
      }
    }
    throw LocalModelException('the local model gave an empty answer');
  }

  /// Text-only role/content pairs. Images are dropped: the local
  /// models answer text only.
  static List<Map<String, String>> _plainMessages(
      List<ChatMessage> messages) {
    return messages
        .map((m) => {'role': m.role, 'content': m.content})
        .toList();
  }

  Future<Map<String, dynamic>> _postJson(
      String url, Map<String, Object> body) async {
    try {
      final request =
          await _client.postUrl(Uri.parse(url)).timeout(chatTimeout);
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.write(jsonEncode(body));
      final response = await request.close().timeout(chatTimeout);
      final text =
          await response.transform(utf8.decoder).join().timeout(chatTimeout);
      if (response.statusCode != 200) {
        throw LocalModelException(
            'the local model server answered ${response.statusCode}');
      }
      final data = jsonDecode(text);
      if (data is! Map<String, dynamic>) {
        throw LocalModelException(
            'the local model gave an unreadable answer');
      }
      return data;
    } on LocalModelException {
      rethrow;
    } on TimeoutException {
      throw LocalModelException('the local model took too long to answer');
    } catch (_) {
      throw LocalModelException('the local model is not running');
    }
  }

  /// The model to use from [models]: the user's pick when it is
  /// installed, else qwen3.5:9b when installed, else the first
  /// model. The answer always says which model answered, so using
  /// the best available model is never hidden from the user.
  static String _pickModel(List<String> models, String? preferred) {
    if (preferred != null &&
        preferred.isNotEmpty &&
        models.contains(preferred)) {
      return preferred;
    }
    if (models.contains(preferredModelName)) return preferredModelName;
    return models.first;
  }

  static List<String> _ollamaNames(Map<String, dynamic> data) {
    final models = data['models'];
    if (models is! List) return [];
    return models
        .whereType<Map>()
        .map((m) => m['name']?.toString() ?? '')
        .where((n) => n.isNotEmpty)
        .toList();
  }

  static List<String> _lmStudioNames(Map<String, dynamic> data) {
    final models = data['data'];
    if (models is! List) return [];
    return models
        .whereType<Map>()
        .map((m) => m['id']?.toString() ?? '')
        .where((n) => n.isNotEmpty)
        .toList();
  }
}
