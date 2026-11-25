// Chat service. Port of src/main/services/chatService.ts.
// Thin orchestration: the brain decides, the services act, this
// file only wires them together. Always returns a response.
//
// JUDGE WIRING (fixes the Electron bug where the UI delete/merge
// path bypassed the judge): deleteDuplicates / mergeDuplicates
// judge first and refuse when blocked. The UI must still confirm.
import '../core/brain.dart';
import '../core/config.dart';
import '../core/judge.dart';
import '../core/models.dart';
import '../core/worker_client.dart';
import 'app_launcher.dart';
import 'duplicate_service.dart';
import 'file_qa.dart';
import 'index_service.dart';
import 'organize_service.dart';
import 'summarize_service.dart';
import 'system_ops.dart';

class ChatService {
  final BrainService brain = BrainService();
  final OrganizeService organize = OrganizeService();
  final DuplicateService duplicates;
  final IndexService indexer;
  final List<String> Function() getFolders;
  final SystemOps systemOps;
  late final AppLauncher appLauncher;

  /// The cloud AI for file questions, or null when no Worker URL is
  /// set. Settable so the app can refresh it when settings change;
  /// ChatService never creates a client itself and never holds a key.
  WorkerClient? cloud;

  /// Which provider/model the cloud answers file questions with.
  CloudProvider cloudProvider;
  String cloudModel;

  ChatService({
    required this.indexer,
    required this.getFolders,
    required this.systemOps,
    DuplicateService? duplicates,
    this.cloud,
    this.cloudProvider = CloudProvider.openai,
    this.cloudModel = 'gpt-4o',
  }) : duplicates = duplicates ?? DuplicateService(systemOps: systemOps) {
    appLauncher = AppLauncher(systemOps);
  }

  String get _home => systemOps.getHomeDir();

  /// Handle one user message. Always returns a response.
  Future<ChatResponse> handle(String text) async {
    final knownFolders = indexer.listFolders().map((f) => f.name).toList();
    final action = brain.decide(text, knownFolders);
    switch (action.action) {
      case 'help':
        return ChatResponseHelp(text: helpText);

      case 'search': {
        final split = splitFolderHint(action.query);
        final results =
            preferInFolder(await indexer.search(split.query, 8), split.hint);
        if (results.isEmpty) {
          return ChatResponseMessage(
            text: "I could not find anything about '${split.query}' in your folders."
                '${_meaningNote()}'
                '\n\nTry different words, or click Rebuild index if you added files recently.\n\n'
                '$helpText',
          );
        }
        return ChatResponseSearch(
          text: "I found ${results.length} file(s) about '${split.query}'. Click Open on any of them.${_meaningNote()}",
          results: results,
        );
      }

      case 'ask': {
        // Question about your files: search (vector + keyword) for
        // the relevant files, give their text to the cloud AI as
        // context, and return the AI's answer with the sources.
        // With no cloud client, FileQA returns the files plus a
        // plain note — Core behaviour, never a made-up answer.
        final qa = FileQA(
          search: indexer.search,
          readText: indexer.getFileText,
          answer: cloud == null
              ? null
              : (messages) => cloud!
                  .chat(
                    provider: cloudProvider,
                    model: cloudModel,
                    messages: messages,
                  )
                  .join(),
        );
        return qa.ask(action.query);
      }

      case 'open': {
        final split = splitFolderHint(action.query);
        final results =
            preferInFolder(await indexer.search(split.query, 8), split.hint);
        if (results.isEmpty) {
          return ChatResponseMessage(
              text: "I could not find a file about '${split.query}'.");
        }
        final top = results[0];
        final opened = await systemOps.openFile(top.path);
        return ChatResponseOpened(
          text: opened.ok
              ? 'Opened ${top.name}.'
              : '${opened.message} Here is what I found instead:',
          results: results,
        );
      }

      case 'openFolder': {
        final matches = indexer.findFolders(action.query);
        if (matches.isEmpty) {
          final known = indexer.listFolders();
          if (known.isEmpty) {
            return ChatResponseMessage(
              text: "I don't know a folder called '${action.query}' yet — I only learn folder names when the index is built.\n\n"
                  'Click Rebuild index once, then ask again.',
            );
          }
          return ChatResponseMessage(
            text: "I don't know a folder called '${action.query}'.\n\n"
                'Folders I know:\n${known.take(12).map((f) => '• ${f.name} — ${f.path}').join('\n')}',
          );
        }
        if (matches.length == 1) {
          final folder = matches[0];
          final opened = await systemOps.openFolder(folder.path);
          return ChatResponseMessage(
            text: opened.ok
                ? 'Opened the ${folder.name} folder.'
                : opened.message,
          );
        }
        return ChatResponseFolders(
          text:
              "I found ${matches.length} folders matching '${action.query}'. Pick one:",
          folders: matches,
        );
      }

      case 'summarize': {
        final results = await indexer.search(action.query, 3);
        if (results.isEmpty) {
          return ChatResponseMessage(
              text:
                  "I could not find a file about '${action.query}' to summarize.");
        }
        final top = results[0];
        final fileText = await indexer.getFileText(top.path);
        final summary = summarizeText(fileText, top.name);
        return ChatResponseSummary(
          text: 'Summary of ${top.name}:',
          fileName: top.name,
          summary: summary.summary,
          note: summary.usedFirstLines
              ? 'Summary from the file itself (first lines) — DJ has no AI model, so it picks the key sentences out of the file.'
              : 'Summary picked from the file itself — DJ has no AI model, so it picks the key sentences out of the file.',
        );
      }

      case 'organize': {
        final range = parseOrganizeRange(action.query);
        if (range == null) {
          return const ChatResponseAskRange(
              text: 'Which days should I organize in Downloads?');
        }
        return planOrganize(range);
      }

      case 'duplicates': {
        final groups = await duplicates.find(getFolders());
        if (groups.isEmpty) {
          return const ChatResponseMessage(
              text: 'I found no extra copies in your folders.');
        }
        final total =
            groups.fold(0, (n, g) => n + (g.files.length - 1));
        final hint = action.query == 'delete'
            ? ' Tick the copies you want rid of, then click Delete selected copies — they go to the Recycle Bin, only after you confirm.'
            : action.query == 'merge'
                ? ' Pick a folder below and click Merge — I will keep one copy where it is and move the rest there.'
                : ' The first copy in each group is always kept.';
        return ChatResponseDuplicates(
          text:
              'I found ${groups.length} group(s) of extra copies ($total extra file(s)).$hint',
          groups: groups,
        );
      }

      case 'list': {
        final recent = indexer.listRecent(10);
        if (recent.isEmpty) {
          return const ChatResponseMessage(
              text: 'I have not indexed any files yet. Click Rebuild index first.');
        }
        return ChatResponseSearch(
          text: 'Here are your newest indexed files:',
          results: recent
              .map((r) => SearchResult(
                    path: r.path,
                    name: r.name,
                    folder: r.folder,
                    snippet: '',
                    score: 0,
                    size: r.size,
                    mtime: DateTime.fromMillisecondsSinceEpoch(
                            r.mtime.round())
                        .toIso8601String(),
                  ))
              .toList(),
        );
      }

      case 'openApp': {
        final result = await appLauncher.openApp(action.query);
        return ChatResponseMessage(text: result.message);
      }

      default:
        return ChatResponseHelp(text: helpText);
    }
  }

  String _meaningNote() {
    if (indexer.lastMeaning == 'loading') {
      return '\n\nMeaning search is still loading — these are keyword matches for now.';
    }
    if (indexer.lastMeaning == 'unavailable') {
      return '\n\nMeaning search is unavailable right now — these are keyword matches.';
    }
    return '';
  }

  /// Plan an organize for a range (used by chat and by the UI).
  ChatResponse planOrganize(OrganizeRange range) {
    final downloads = getDownloadsDir(_home);
    final plan = organize.plan(downloads, range);
    if (plan.isEmpty) {
      return ChatResponseMessage(
        text:
            'Nothing to organize in Downloads for ${rangeLabel(range)} — no files added then.',
      );
    }
    return ChatResponseOrganizePlan(
      text:
          'Here is what I will move in Downloads (${rangeLabel(range)}). Nothing moves until you say Yes.',
      label: rangeLabel(range),
      range: range,
      plan: plan,
    );
  }

  /// Carry out an organize plan the user confirmed.
  ChatResponse applyOrganize(List<OrganizeMove> plan) {
    final downloads = getDownloadsDir(_home);
    final result = organize.apply(plan, downloads);
    return ChatResponseOrganizeDone(
      text: result.moved.isNotEmpty
          ? 'Moved ${result.moved.length} file(s). Every move is in ${result.logPath}.'
          : 'Nothing was moved.',
      moved: result.moved,
      errors: result.errors,
      logPath: result.logPath,
    );
  }

  /// Delete picked duplicate copies to the Recycle Bin. Judged
  /// first: with no clear target the delete is blocked and nothing
  /// runs. The UI still asks the user to confirm.
  Future<({List<String> deleted, List<String> errors, String logPath})>
      deleteDuplicates(List<String> paths) async {
    final judged = judgeAction(JudgeInput(
      kind: 'delete',
      text: 'delete the extra copies',
      destructive: true,
      targetCount: paths.length,
    ));
    if (judged.blocked.isNotEmpty) {
      return (deleted: <String>[], errors: judged.blocked, logPath: '');
    }
    return duplicates.deleteToRecycleBin(getDownloadsDir(_home), paths);
  }

  /// Merge one duplicate group into a folder the user picked.
  /// Judged first, same as delete.
  ({List<String> moved, List<String> errors}) mergeDuplicates(
      List<String> paths, String targetFolder) {
    final judged = judgeAction(JudgeInput(
      kind: 'merge',
      text: 'merge the extra copies into $targetFolder',
      destructive: true,
      targetCount: paths.length,
    ));
    if (judged.blocked.isNotEmpty) {
      return (moved: <String>[], errors: judged.blocked);
    }
    return duplicates.merge(paths, targetFolder);
  }
}

/// Split "index.html in AuPro" into the file to find ("index.html")
/// and the project hint ("AuPro"). Without " in " there is no hint.
({String query, String hint}) splitFolderHint(String query) {
  final m = RegExp(r'^(.+?)\s+in\s+([a-z0-9][a-z0-9 ]*?)\s*$',
          caseSensitive: false)
      .firstMatch(query);
  if (m == null) return (query: query.trim(), hint: '');
  return (query: (m.group(1) ?? '').trim(), hint: (m.group(2) ?? '').trim());
}

/// Prefer search results that live under the hinted project folder.
List<SearchResult> preferInFolder(List<SearchResult> results, String hint) {
  final h = hint.trim().toLowerCase();
  if (h.isEmpty) return results;
  final matching = results
      .where((r) =>
          r.folder.toLowerCase().contains(h) ||
          r.path.toLowerCase().contains(h))
      .toList();
  if (matching.isEmpty) return results;
  final rest = results.where((r) => !matching.contains(r)).toList();
  return [...matching, ...rest];
}
