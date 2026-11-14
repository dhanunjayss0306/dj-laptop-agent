// DJ v5.3 — isair/jarvis inclusion (idea only, no isair code).
// isair Jarvis is voice-first: it listens to the room, keeps a short
// rolling transcript of nearby speech, and answers only when it is
// addressed by name ("Jarvis, what do you think?"). It runs two
// models: a small fast one that judges intent, and a larger chat
// model that answers. DJ takes that shape, without bundling any big
// model:
//
//   - Name-addressed listening: "DJ, ..." in text or speech. DJ
//     ignores everything that is not addressed to it.
//   - Rolling transcript: the last few seconds of speech, kept in
//     memory only, so DJ can answer from the conversation, not just
//     the last sentence.
//   - Two-model routing: quick classifications go to the fast judge
//     (or, with no model running, to Core rules); full answers go
//     to the chat model when one is up, and to Core rules when not.
//   - Diary + knowledge graph memory: short dated lines in plain
//     text files on this laptop, never in the cloud.
//   - Dictation: where the browser supports it, Web Speech API
//     transcribes locally into any text box. No new binary, no
//     bundled speech model.

export interface AddressedQuery {
  /** True when the words are addressed to DJ by name. */
  addressed: boolean;
  /** The query with the name stripped off. */
  query: string;
  /** The wake word used, when one was. */
  wakeWord: string | null;
}

/** "DJ, find my notes" -> addressed, "find my notes". "hey DJ open
 *  chrome" -> addressed. Anything without the name -> not addressed.
 *  Matching is case-insensitive and ignores leading filler. */
export function parseAddressed(text: string): AddressedQuery {
  const raw = (text || '').trim();
  const m = raw.match(/^(?:hey|ok|okay|hello|hi)?\s*dj\b[\s,:\-]*/i);
  if (!m) return { addressed: false, query: raw, wakeWord: null };
  const wakeWord = /^(hey|ok|okay|hello|hi)/i.test(m[0].trim())
    ? m[0].trim().split(/\s+/)[0].toLowerCase()
    : 'dj';
  return {
    addressed: true,
    query: raw.slice(m[0].length).trim(),
    wakeWord,
  };
}

/** The fast judge vs the chat model, as a routing decision. With no
 *  model running, everything routes to Core rules — the router never
 *  assumes a model exists. */
export type ModelRoute = 'fast-judge' | 'chat-model' | 'core-rules';

export function routeTask(task: {
  kind: 'classify' | 'answer' | 'command' | 'dictate';
  modelUp: boolean;
}): ModelRoute {
  if (!task.modelUp) return 'core-rules';
  if (task.kind === 'classify' || task.kind === 'command') return 'fast-judge';
  return 'chat-model';
}

/** One short rolling-transcript segment. Kept in memory only. */
export interface TranscriptSegment {
  text: string;
  at: number;
}

/** Keeps the last N seconds of nearby speech, so DJ can answer from
 *  the conversation, not just the last sentence. Nothing is stored
 *  on disk; old segments drop off. */
export class RollingTranscript {
  private readonly segments: TranscriptSegment[] = [];

  constructor(
    private readonly maxSegments = 20,
    private readonly windowMs = 30_000,
  ) {}

  add(text: string, at = Date.now()): void {
    const t = (text || '').trim();
    if (!t) return;
    this.segments.push({ text: t, at });
    this.prune(at);
    while (this.segments.length > this.maxSegments) this.segments.shift();
  }

  /** The recent conversation as one block of text. */
  recent(at = Date.now()): string {
    this.prune(at);
    return this.segments.map((s) => s.text).join(' ');
  }

  /** The latest segment addressed to DJ, if any. */
  findAddressed(at = Date.now()): AddressedQuery | null {
    this.prune(at);
    for (let i = this.segments.length - 1; i >= 0; i--) {
      const parsed = parseAddressed(this.segments[i].text);
      if (parsed.addressed) return parsed;
    }
    return null;
  }

  private prune(at: number): void {
    while (this.segments.length > 0 && at - this.segments[0].at > this.windowMs) {
      this.segments.shift();
    }
  }
}

/** One diary line: a dated fact for the diary + knowledge graph.
 *  Plain text, stored in local memory files, never in the cloud. */
export interface DiaryEntry {
  at: string;
  kind: string;
  text: string;
}

export function diaryLine(entry: DiaryEntry): string {
  return `- ${entry.at} [${entry.kind}] ${entry.text}`;
}
