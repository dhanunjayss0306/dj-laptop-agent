// Text helpers: chunking and snippets. Port of src/main/utils/text.ts.
const int chunkWords = 400;
const int overlapWords = 50;

/// Chunking scheme version, stored beside the vectors. Bump when
/// chunkText / chunkPdfText change shape.
const int chunkVersion = 1;

/// Split text into overlapping word chunks (400 words, 50 overlap).
List<String> chunkText(String text) {
  final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return [];
  final chunks = <String>[];
  var start = 0;
  while (start < words.length) {
    final end = start + chunkWords < words.length ? start + chunkWords : words.length;
    chunks.add(words.sublist(start, end).join(' '));
    if (end >= words.length) break;
    start = end - overlapWords;
  }
  return chunks;
}

/// Split PDF text into page-aware chunks. Pages are split on form
/// feed (\f); each page is chunked on its own and tagged "[page N] ".
/// Text without page marks falls back to plain chunkText.
List<String> chunkPdfText(String text) {
  final pages = text.split('\f');
  if (pages.length <= 1) return chunkText(text);
  final chunks = <String>[];
  for (var i = 0; i < pages.length; i++) {
    if (pages[i].trim().isEmpty) continue;
    for (final c in chunkText(pages[i])) {
      chunks.add('[page ${i + 1}] $c');
    }
  }
  return chunks;
}

/// A short piece of text around the first query word found in it.
String snippet(String text, String query, [int length = 160]) {
  final words = query
      .toLowerCase()
      .split(RegExp(r'\W+'))
      .where((w) => w.length > 2)
      .toList();
  final low = text.toLowerCase();
  var pos = -1;
  for (final w in words) {
    pos = low.indexOf(w);
    if (pos != -1) break;
  }
  final start = pos == -1 ? 0 : (pos - 40 < 0 ? 0 : pos - 40);
  final piece = pos == -1
      ? text.substring(0, text.length < length ? text.length : length)
      : text.substring(start, start + length < text.length ? start + length : text.length);
  final clean = piece.replaceAll(RegExp(r'\s+'), ' ').trim();
  return clean.length > length ? '${clean.substring(0, length)}...' : clean;
}

/// How many times [needle] appears in [haystack] (non-overlapping).
int countOccurrences(String haystack, String needle) {
  if (needle.isEmpty) return 0;
  var count = 0;
  var i = haystack.indexOf(needle);
  while (i != -1) {
    count += 1;
    i = haystack.indexOf(needle, i + needle.length);
  }
  return count;
}
