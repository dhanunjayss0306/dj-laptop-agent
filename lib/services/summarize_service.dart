// Extractive summary. Port of src/main/services/summarizeService.ts.
// No model, no LLM, no generative summary. The UI must keep saying so.
class SummaryResult {
  final String summary;
  final bool usedFirstLines;
  const SummaryResult({required this.summary, required this.usedFirstLines});
}

const int _maxSentences = 5;

int _scoreSentence(String sentence, List<String> keywords) {
  final words = sentence.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.length < 4) return -100;
  if (words.length > 60) return -50;
  var score = words.length < 30 ? words.length : 30;
  final low = sentence.toLowerCase();
  for (final kw in keywords) {
    if (kw.isNotEmpty && low.contains(kw)) score += 5;
  }
  return score;
}

SummaryResult summarizeText(String text, String fileName) {
  final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (clean.isEmpty) {
    return const SummaryResult(
      summary: 'That file looks empty, so there is nothing to summarize.',
      usedFirstLines: true,
    );
  }
  // Keywords: words from the file name (without extension).
  final keywords = fileName
      .replaceFirst(RegExp(r'\.[^.]+$'), '')
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((w) => w.length > 2)
      .toList();

  final sentences = clean
      .split(RegExp(r'(?<=[.!?])\s+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  if (sentences.length <= _maxSentences) {
    return SummaryResult(summary: sentences.join(' '), usedFirstLines: true);
  }
  final scored = <({String s, int i, int score})>[];
  for (var i = 0; i < sentences.length; i++) {
    final score = _scoreSentence(sentences[i], keywords);
    if (score > 0) scored.add((s: sentences[i], i: i, score: score));
  }
  scored.sort((a, b) => b.score.compareTo(a.score));
  final top = scored.take(_maxSentences).toList()
    ..sort((a, b) => a.i.compareTo(b.i));
  final picked = top.isNotEmpty
      ? top
      : sentences
          .take(_maxSentences)
          .toList()
          .asMap()
          .entries
          .map((e) => (s: e.value, i: e.key, score: 0))
          .toList();
  return SummaryResult(
    summary: picked.map((p) => '• ${p.s}').join('\n'),
    usedFirstLines: false,
  );
}
