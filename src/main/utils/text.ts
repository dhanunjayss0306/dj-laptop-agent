// DJ v3 — text helpers: chunking and snippets. Same rules as the
// Python version: chunks of about 400 words, overlapping by 50 words
// so a sentence that straddles a boundary is not lost.

export const CHUNK_WORDS = 400;
export const OVERLAP_WORDS = 50;

/**
 * Chunking scheme version, stored beside the vectors. When the
 * chunking rules change, stored vectors built with the old rules
 * must not be reused for the files whose chunking changed (PDFs
 * became page-aware in v5.5). Bump this when chunkText or
 * chunkPdfText changes shape.
 */
export const CHUNK_VERSION = 1;

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

/**
 * Split PDF text into page-aware chunks. pdf-parse marks page
 * breaks with a form feed (\f), so each page is chunked on its
 * own and tagged with its page number ("[page 3] ...") — a search
 * hit then says which page it came from, and a sentence never
 * straddles two pages. Pages with no text are skipped. Text
 * without page marks falls back to plain chunkText.
 */
export function chunkPdfText(text: string): string[] {
  const pages = text.split('\f');
  if (pages.length <= 1) return chunkText(text);
  const chunks: string[] = [];
  pages.forEach((page, i) => {
    if (!page.trim()) return;
    for (const c of chunkText(page)) {
      chunks.push(`[page ${i + 1}] ${c}`);
    }
  });
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
