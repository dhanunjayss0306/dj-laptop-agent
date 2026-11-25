// File Q&A tests — question → search → context → AI answer.
//
// The vector database is NOT involved in producing answers here:
// the shipped embedder is NotStartedEmbedder, so these tests run on
// keyword search. They prove the wiring (brain routes the question,
// FileQA retrieves files, gives their text to the AI as context,
// returns the answer with the sources, and falls back plainly
// when there is no AI or the AI call fails).
import 'dart:io';

import 'package:dj/core/brain.dart';
import 'package:dj/core/models.dart';
import 'package:dj/core/worker_client.dart';
import 'package:dj/services/chat_service.dart';
import 'package:dj/services/file_qa.dart';
import 'package:dj/services/index_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/fakes.dart';

void main() {
  group('brain routes content questions to ask', () {
    final brain = BrainService();

    test('what-question goes to ask', () {
      final a = brain.decide('what does my Virun pitch say about pricing?');
      expect(a.action, 'ask');
      expect(a.query, 'what does my Virun pitch say about pricing?');
    });

    test('where-is stays a file search', () {
      expect(brain.decide('where is my pitch').action, 'search');
      expect(brain.decide('where is my pitch?').action, 'search');
    });

    test('find stays a file search', () {
      expect(brain.decide('find my notes').action, 'search');
    });

    test('help still wins', () {
      expect(brain.decide('what can you do').action, 'help');
    });
  });

  group('file Q&A', () {
    late Directory tmp;
    late IndexService indexer;
    late ChatService chat;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('dj-qa-');
      final dataDir = Directory('${tmp.path}/dj_data')..createSync();
      final docs = Directory('${tmp.path}/Docs')..createSync();
      File('${docs.path}/virun-pitch.txt').writeAsStringSync(
          'Virun is a travel and tourism platform for India with local guides. Pricing is Rs 499 per trip.');
      indexer = IndexService(
          dataDir: dataDir.path, embedder: NotStartedEmbedder());
      await indexer.build(['${tmp.path}/Docs']);
      chat = ChatService(
          indexer: indexer,
          getFolders: () => ['${tmp.path}/Docs'],
          systemOps: FakeSystemOps());
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('ask with an AI returns the answer with the source files',
        () async {
      List<ChatMessage>? seen;
      final qa = FileQA(
        search: indexer.search,
        readText: indexer.getFileText,
        answer: (messages) async {
          seen = messages;
          return 'The pitch says pricing is Rs 499 per trip.';
        },
      );
      final r = await qa.ask('what does my Virun pitch say about pricing?');
      expect(r.kind, 'search');
      final s = r as ChatResponseSearch;
      expect(s.text, contains('Rs 499'));
      expect(s.results.first.name, 'virun-pitch.txt');
      // The AI got the file excerpt as context.
      expect(seen!.first.role, 'system');
      expect(seen!.last.content, contains('Rs 499 per trip'));
    });

    test('ask with no AI returns the files and says so plainly', () async {
      final qa = FileQA(
        search: indexer.search,
        readText: indexer.getFileText,
      );
      final r = await qa.ask('what does my Virun pitch say about pricing?');
      expect(r.kind, 'search');
      final s = r as ChatResponseSearch;
      expect(s.text, contains('needs an AI'));
      expect(s.results.first.name, 'virun-pitch.txt');
    });

    test('ask with no matching files says so', () async {
      final qa = FileQA(
        search: indexer.search,
        readText: indexer.getFileText,
        answer: (_) async => 'should not be called',
      );
      final r = await qa.ask('what does my zzzqqq file say?');
      expect(r.kind, 'message');
      expect(r.text, contains('could not find anything'));
    });

    test('ask falls back to the files when the AI call fails', () async {
      final qa = FileQA(
        search: indexer.search,
        readText: indexer.getFileText,
        answer: (_) async => throw WorkerException('worker error (500)'),
      );
      final r = await qa.ask('what does my Virun pitch say about pricing?');
      expect(r.kind, 'search');
      final s = r as ChatResponseSearch;
      expect(s.text, contains('did not answer'));
      expect(s.results.first.name, 'virun-pitch.txt');
    });

    test('chat routes a question to ask and falls back without any AI',
        () async {
      final r =
          await chat.handle('what does my Virun pitch say about pricing?');
      expect(r.kind, 'search');
      final s = r as ChatResponseSearch;
      expect(s.text, contains('No AI answered'));
      expect(s.results.first.name, 'virun-pitch.txt');
    });
  });
}
