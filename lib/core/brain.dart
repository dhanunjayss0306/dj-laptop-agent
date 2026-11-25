// Rules brain. Port of src/main/services/brainService.ts — pure
// keyword/pattern rules, no model. Routing order (first match wins):
// help → duplicates → organize → summarize → folder → open/app →
// find/search → list → default search.
import 'models.dart';

const Set<String> knownApps = {
  'notepad',
  'chrome',
  'calculator',
  'paint',
  'word',
  'excel',
  'powerpoint',
  'edge',
  'vs code',
  'code',
  'spotify',
  'whatsapp',
  'explorer',
  'file explorer',
  'settings',
  'cmd',
  'terminal',
  'clock',
};

const String helpText = '''Here is what I can do:
• find my Virun pitch — find files by name or topic
• open something about travel and tourism — open files by what is inside them
• open the frontend folder — open a folder by name (in Explorer)
• open index.html in AuPro — open a file inside a project folder
• summarize my Virun pitch — a short summary of a file
• organize yesterday's Downloads — tidy Downloads (today, yesterday, last 3 days, this week, everything)
• find duplicates — find extra copies of the same file
• delete the extra copies — delete the copies you pick, to the Recycle Bin
• merge the extra copies — keep one copy, move the rest into one folder
• open notepad — open an installed app by name
• list recent files — show the newest files I know about
• what does my Virun pitch say about pricing? — ask a question about your files (needs the cloud AI)''';

class BrainService {
  /// Turn the user's words into an action. Always returns one.
  ChatAction decide(String text, [List<String> knownFolders = const []]) {
    final raw = text.trim();
    final low = raw.toLowerCase();
    if (low.isEmpty) return const ChatAction(action: 'help', query: '');

    if (low == 'help' ||
        low.contains('what can you do') ||
        low.contains('help me')) {
      return const ChatAction(action: 'help', query: '');
    }

    if (low.contains('duplicat') ||
        low.contains('extra cop') ||
        low.contains('same file')) {
      if (low.contains('merge')) {
        return const ChatAction(action: 'duplicates', query: 'merge');
      }
      return ChatAction(
          action: 'duplicates', query: low.contains('delet') ? 'delete' : '');
    }

    if (low.contains('organiz')) {
      return ChatAction(
          action: 'organize', query: parseOrganizeRangeText(low) ?? '');
    }

    if (low.contains('summar')) {
      final query = _afterWords(low, [
        'summarize this file',
        'summarise this file',
        'summarize',
        'summarise',
        'summary of',
      ]);
      return ChatAction(action: 'summarize', query: query.isEmpty ? raw : query);
    }

    final folderQuery = extractFolderQuery(raw);
    if (folderQuery != null) {
      return ChatAction(action: 'openFolder', query: folderQuery);
    }

    final known = knownFolders.map((f) => f.toLowerCase()).toSet();

    if (low.startsWith('open ')) {
      var rest = raw.substring(5).trim();
      rest = rest.replaceFirst(
          RegExp(
              r'^(something|anything|all the things|the files?|a file)\s+(about|on|related to)\s+',
              caseSensitive: false),
          '');
      rest = rest.replaceFirst(
          RegExp(r'^(something|anything)\s+about\s+', caseSensitive: false),
          '');
      if (knownApps.contains(rest.toLowerCase())) {
        return ChatAction(action: 'openApp', query: rest.toLowerCase());
      }
      final folderCandidate =
          rest.replaceFirst(RegExp(r'^(the|a|an|my)\s+', caseSensitive: false), '').trim();
      if (folderCandidate.isNotEmpty &&
          known.contains(folderCandidate.toLowerCase())) {
        return ChatAction(action: 'openFolder', query: folderCandidate);
      }
      return ChatAction(action: 'open', query: rest.isEmpty ? raw : rest);
    }

    for (final word in [
      'find ',
      'search for ',
      'search ',
      'look for ',
      'where is ',
      'where are ',
      'show me ',
    ]) {
      if (low.startsWith(word)) {
        final query = raw.substring(word.length).trim();
        final folderCandidate = query
            .replaceFirst(RegExp(r'^(the|a|an|my)\s+', caseSensitive: false), '')
            .trim();
        if (folderCandidate.isNotEmpty &&
            known.contains(folderCandidate.toLowerCase())) {
          return ChatAction(action: 'openFolder', query: folderCandidate);
        }
        return ChatAction(action: 'search', query: query);
      }
    }

    if (low.startsWith('list ') || low.startsWith('show ')) {
      return ChatAction(action: 'list', query: raw);
    }

    // A content question ("what does my pitch say about pricing?"):
    // ask the AI with the matching files as context. File-finding
    // words above (find/search/where is/...) already returned, so
    // only real questions reach here.
    if (raw.endsWith('?') && _isContentQuestion(low)) {
      return ChatAction(action: 'ask', query: raw);
    }

    return ChatAction(action: 'search', query: raw);
  }
}

/// True when the message starts with a question word about content
/// (what/why/how/when/who/which). "where" is not one — "where is my
/// pitch" is a file search, not a question to answer.
bool _isContentQuestion(String low) {
  for (final w in ['what', 'why', 'how', 'when', 'who', 'which']) {
    if (low.startsWith('$w ') || low == w) return true;
  }
  return false;
}

/// The folder a "… folder …" message asks for, or null when the
/// message is not about a folder at all. "" means "a folder, but no
/// name given" — the chat service then lists the folders DJ knows.
String? extractFolderQuery(String text) {
  final low = text.toLowerCase();
  final folderMatch =
      RegExp(r'\b(?:folder|folders|directory|directories)\b').firstMatch(low);
  if (folderMatch == null) return null;
  final folderIdx = folderMatch.start;
  final before = text.substring(0, folderIdx);
  final verbMatches = RegExp(r'\b(?:open|find|show|go to|go)\b',
          caseSensitive: false)
      .allMatches(before)
      .toList();
  var name = '';
  if (verbMatches.isNotEmpty) {
    final last = verbMatches.last;
    name = _cleanFolderWords(before.substring(last.end));
  }
  final inAfter = RegExp(
          r'\b(?:folder|directory)\b[^a-z0-9]*in\s+([a-z0-9][a-z0-9 ]*?)\s*$',
          caseSensitive: false)
      .firstMatch(text.substring(folderIdx));
  final project =
      inAfter != null ? _cleanFolderWords(inAfter.group(1) ?? '') : '';
  if (name.isNotEmpty && project.isNotEmpty) return '$name $project';
  if (name.isNotEmpty) return name;
  if (project.isNotEmpty) return project;
  return '';
}

String _cleanFolderWords(String s) {
  const drop = {'the', 'a', 'an', 'that', 'this', 'related', 'my', 'me'};
  return s
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty && !drop.contains(w.toLowerCase()))
      .join(' ')
      .trim();
}

/// The date range in the user's words ("today", "yesterday",
/// "last 3 days", "all"), or null if no range was mentioned.
String? parseOrganizeRangeText(String low) {
  if (RegExp(r'\b(all|everything|every file)\b').hasMatch(low)) return 'all';
  if (low.contains('yesterday')) return 'yesterday';
  final m = RegExp(r'(?:last|past)\s+(\d+)\s+days?').firstMatch(low);
  if (m != null) {
    final n = int.parse(m.group(1)!).clamp(1, 1 << 30);
    return 'last $n day${n != 1 ? 's' : ''}';
  }
  if (low.contains('this week') || low.contains('last week')) {
    return 'last 7 days';
  }
  if (low.contains('today')) return 'today';
  return null;
}

/// Parse a range string into a structured range.
OrganizeRange? parseOrganizeRange(String text) {
  final low = text.toLowerCase();
  if (RegExp(r'\b(all|everything|every file)\b').hasMatch(low)) {
    return const OrganizeRangeAll();
  }
  if (low.contains('yesterday')) return const OrganizeRangeYesterday();
  final m = RegExp(r'(?:last|past)\s+(\d+)\s+days?').firstMatch(low);
  if (m != null) {
    return OrganizeRangeLastDays(days: int.parse(m.group(1)!).clamp(1, 1 << 30));
  }
  if (low.contains('this week') || low.contains('last week')) {
    return const OrganizeRangeLastDays(days: 7);
  }
  if (low.contains('today')) return const OrganizeRangeToday();
  return null;
}

/// Plain words for a range, for the preview window.
String rangeLabel(OrganizeRange range) {
  return switch (range) {
    OrganizeRangeToday() => 'today',
    OrganizeRangeYesterday() => 'yesterday',
    OrganizeRangeLastDays(:final days) =>
      'the last $days day${days != 1 ? 's' : ''}',
    OrganizeRangeAll() => 'all files',
  };
}

String _afterWords(String text, List<String> words) {
  for (final w in words) {
    final i = text.indexOf(w);
    if (i >= 0) {
      return text
          .substring(i + w.length)
          .trim()
          .replaceFirst(RegExp(r'^[:\s]+'), '');
    }
  }
  return '';
}
