// Voice assistant — pure functions only. Port of src/main/v53/voice.ts.
//
// HONEST STATUS: there is no working voice assistant in the
// Electron app — no mic capture, no STT, no TTS, no wake-word
// listener. Only these pure functions are ported here. Mic/STT/TTS
// is a separate platform task, not this one.
class AddressedQuery {
  final bool addressed;
  final String query;
  final String? wakeWord;
  const AddressedQuery(
      {required this.addressed, required this.query, this.wakeWord});
}

/// "DJ, find my notes" -> addressed, "find my notes".
/// "hey DJ open chrome" -> addressed. Anything without the name
/// -> not addressed. Case-insensitive, ignores leading filler.
AddressedQuery parseAddressed(String text) {
  final raw = text.trim();
  final m = RegExp(r'^(?:hey|ok|okay|hello|hi)?\s*dj\b[\s,:\-]*',
          caseSensitive: false)
      .firstMatch(raw);
  if (m == null) return AddressedQuery(addressed: false, query: raw);
  final matched = m.group(0)!;
  final wakeWord = RegExp(r'^(hey|ok|okay|hello|hi)', caseSensitive: false)
          .hasMatch(matched.trim())
      ? matched.trim().split(RegExp(r'\s+')).first.toLowerCase()
      : 'dj';
  return AddressedQuery(
    addressed: true,
    query: raw.substring(m.end).trim(),
    wakeWord: wakeWord,
  );
}

typedef ModelRoute = String; // 'fast-judge' | 'chat-model' | 'core-rules'

/// The fast judge vs the chat model, as a routing decision. With no
/// model running, everything routes to Core rules.
String routeTask({required String kind, required bool modelUp}) {
  if (!modelUp) return 'core-rules';
  if (kind == 'classify' || kind == 'command') return 'fast-judge';
  return 'chat-model';
}

class TranscriptSegment {
  final String text;
  final int at; // ms since epoch
  const TranscriptSegment({required this.text, required this.at});
}

/// Keeps the last N seconds of nearby speech, in memory only.
/// Nothing is stored on disk; old segments drop off.
class RollingTranscript {
  final List<TranscriptSegment> _segments = [];
  final int maxSegments;
  final int windowMs;

  RollingTranscript({this.maxSegments = 20, this.windowMs = 30000});

  void add(String text, [int? at]) {
    final t = text.trim();
    if (t.isEmpty) return;
    final now = at ?? DateTime.now().millisecondsSinceEpoch;
    _segments.add(TranscriptSegment(text: t, at: now));
    _prune(now);
    while (_segments.length > maxSegments) {
      _segments.removeAt(0);
    }
  }

  /// The recent conversation as one block of text.
  String recent([int? at]) {
    _prune(at ?? DateTime.now().millisecondsSinceEpoch);
    return _segments.map((s) => s.text).join(' ');
  }

  /// The latest segment addressed to DJ, if any.
  AddressedQuery? findAddressed([int? at]) {
    _prune(at ?? DateTime.now().millisecondsSinceEpoch);
    for (var i = _segments.length - 1; i >= 0; i--) {
      final parsed = parseAddressed(_segments[i].text);
      if (parsed.addressed) return parsed;
    }
    return null;
  }

  void _prune(int at) {
    while (_segments.isNotEmpty && at - _segments.first.at > windowMs) {
      _segments.removeAt(0);
    }
  }
}

class DiaryEntry {
  final String at;
  final String kind;
  final String text;
  const DiaryEntry({required this.at, required this.kind, required this.text});
}

/// One diary line: `- <at> [<kind>] <text>`.
String diaryLine(DiaryEntry entry) => '- ${entry.at} [${entry.kind}] ${entry.text}';
