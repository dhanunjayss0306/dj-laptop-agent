// DJ v3 — text helpers: chunking and snippets. Same rules as the
// Python version: chunks of about 400 words, overlapping by 50 words
// so a sentence that straddles a boundary is not lost.

export const CHUNK_WORDS = 400;
export const OVERLAP_WORDS = 50;

/** Split text into overlapping word chunks. */
export function chunkText(text: string): string[] {
  const words = text.split(/\s+/).filter(Boolean);
  if (words.length === 0) return [];
  const chunks: string[] = [];
  let start = 0;
  while (start < words.length) {
    const end = Math.min(start + CHUNK_WORDS, words.length);
    chunks.push(words.slice(start, end).join(' '));
    if (end >= words.length) break;
    start = end - OVERLAP_WORDS;
  }
  return chunks;
}

/** A short piece of text around the first query word found in it. */
export function snippet(text: string, query: string, length = 160): string {
  const words = query
    .toLowerCase()
    .split(/\W+/)
    .filter((w) => w.length > 2);
  const low = text.toLowerCase();
  let pos = -1;
  for (const w of words) {
    pos = low.indexOf(w);
    if (pos !== -1) break;
  }
  const piece =
    pos === -1 ? text.slice(0, length) : text.slice(Math.max(0, pos - 40), pos - 40 + length);
  const clean = piece.replace(/\s+/g, ' ').trim();
  return clean.length > length ? clean.slice(0, length) + '...' : clean;
}

/** Score helper: how many times a word appears, capped. */
export function countOccurrences(haystack: string, needle: string): number {
  if (!needle) return 0;
  let count = 0;
  let i = haystack.indexOf(needle);
  while (i !== -1) {
    count += 1;
    i = haystack.indexOf(needle, i + needle.length);
  }
  return count;
}
