// DJ v3 — extractive summary. There is no LLM, so DJ summarizes
// by picking the most informative sentences out of the file itself.
// The UI says so plainly ("summary from the file itself, no AI").
// DJ never writes into a file — this only reads.

export interface SummaryResult {
  summary: string;
  /** True when the file was too short to pick sentences from. */
  usedFirstLines: boolean;
}

const MAX_SENTENCES = 5;

/** Score a sentence: longer informative sentences win; headings and
 *  very short lines lose. */
function scoreSentence(sentence: string, keywords: string[]): number {
  const words = sentence.split(/\s+/).filter(Boolean);
  if (words.length < 4) return -100;
  if (words.length > 60) return -50;
  let score = Math.min(words.length, 30);
  const low = sentence.toLowerCase();
  for (const kw of keywords) {
    if (kw && low.includes(kw)) score += 5;
  }
  return score;
}

export function summarizeText(text: string, fileName: string): SummaryResult {
  const clean = (text || '').replace(/\s+/g, ' ').trim();
  if (!clean) {
    return {
      summary: 'That file looks empty, so there is nothing to summarize.',
      usedFirstLines: true,
    };
  }
  // Keywords: words from the file name (without extension).
  const keywords = fileName
    .replace(/\.[^.]+$/, '')
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter((w) => w.length > 2);

  const sentences = clean
    .split(/(?<=[.!?])\s+/)
    .map((s) => s.trim())
    .filter((s) => s.length > 0);

  if (sentences.length <= MAX_SENTENCES) {
    return { summary: sentences.join(' '), usedFirstLines: true };
  }
  const scored = sentences
    .map((s, i) => ({ s, i, score: scoreSentence(s, keywords) }))
    .filter((x) => x.score > 0)
    .sort((a, b) => b.score - a.score)
    .slice(0, MAX_SENTENCES)
    .sort((a, b) => a.i - b.i);
  const picked = scored.length > 0 ? scored : sentences.slice(0, MAX_SENTENCES).map((s, i) => ({ s, i, score: 0 }));
  return {
    summary: picked.map((p) => `• ${p.s}`).join('\n'),
    usedFirstLines: false,
  };
}
