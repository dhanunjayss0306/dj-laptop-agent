// File Q&A — the question → search → context → AI answer path.
//
// Ask a question about your files and DJ:
//   1. searches the local index (vector search when the embedder is
//      ready, keyword search always) for the most relevant files,
//   2. reads the top files' text and gives those excerpts to the AI
//      as context,
//   3. returns the AI's answer together with the source files.
//
// The AI is injected as [AnswerFn]. When it is null there is no AI
// available (no Worker URL, no internet, no key) and DJ says so
// plainly and returns the matching files instead — Core behaviour,
// never a made-up answer. When the AI call itself fails, DJ falls
// back to the files the same way.

import '../core/models.dart';
import '../core/worker_client.dart';

typedef SearchFn = Future<List<SearchResult>> Function(String query,
    [int topN]);
typedef ReadTextFn = Future<String> Function(String path, [int maxChars]);
typedef AnswerFn = Future<String> Function(List<ChatMessage> messages);

/// How much of each source file is given to the AI as context.
const int qaExcerptChars = 3000;

/// How many source files are given to the AI as context.
const int qaTopFiles = 3;

const String qaSystemPrompt =
    'You answer questions using ONLY the file excerpts below. '
    'If the excerpts do not contain the answer, say so plainly. '
    'Keep the answer short.';

class FileQA {
  FileQA({
    required this.search,
    required this.readText,
    this.answer,
  });

  final SearchFn search;
  final ReadTextFn readText;

  /// The AI that answers, or null when no AI is available.
  final AnswerFn? answer;

  Future<ChatResponse> ask(String question) async {
    final q = question.trim();
    final results = await search(q, qaTopFiles);
    if (results.isEmpty) {
      return ChatResponseMessage(
        text: "I could not find anything about '$q' in your files.",
      );
    }
    if (answer == null) {
      return ChatResponseSearch(
        text: "I found ${results.length} file(s) about '$q'. "
            'Answering in words needs the cloud AI — set the Worker URL '
            'in Settings first. Here is what I found:',
        results: results,
      );
    }
    final parts = <String>[];
    for (final r in results) {
      String text = '';
      try {
        text = await readText(r.path, qaExcerptChars);
      } catch (_) {
        // Unreadable file: still list it as a source, with no excerpt.
      }
      parts.add('--- ${r.name} ---\n$text');
    }
    final messages = <ChatMessage>[
      const ChatMessage(role: 'system', content: qaSystemPrompt),
      ChatMessage(
        role: 'user',
        content: 'Question: $q\n\nFile excerpts:\n${parts.join('\n\n')}',
      ),
    ];
    try {
      final reply = (await answer!(messages)).trim();
      return ChatResponseSearch(
        text: reply.isEmpty ? 'The cloud AI gave an empty answer.' : reply,
        results: results,
      );
    } catch (_) {
      return ChatResponseSearch(
        text: 'The cloud AI did not answer. Here are the files I found '
            "about '$q':",
        results: results,
      );
    }
  }
}
