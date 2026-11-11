// DJ v3 — rules brain. DJ understands the user's words with plain
// pattern matching — no LLM, no model, no server. His commands are
// a fixed set, so rules are enough, and they use almost no memory.
//
// Actions:
//   search     — find files by name or topic
//   open       — open a file the user names, or files about a topic
//   openFolder — open a folder the user names ("open the frontend folder")
//   summarize  — summarize a file the user names
//   organize   — organize Downloads for a date range
//   duplicates — find extra copies of the same file
//   list       — list files, e.g. recent files
//   openApp    — open an installed app by name
//   help       — what DJ can do
//
// When DJ cannot work out what was asked, it falls back to a plain
// search of the words — and when even that finds nothing, the UI
// says so plainly and lists what DJ can do.

import type { ChatAction, OrganizeRange } from '../../shared/types';

const KNOWN_APPS = new Set([
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
]);

export const HELP_TEXT = [
  'Here is what I can do:',
  '• find my Virun pitch — find files by name or topic',
  '• open something about travel and tourism — open files by what is inside them',
  '• open the frontend folder — open a folder by name (in Explorer)',
  '• open index.html in AuPro — open a file inside a project folder',
  '• summarize my Virun pitch — a short summary of a file',
  "• organize yesterday's Downloads — tidy Downloads (today, yesterday, last 3 days, this week, everything)",
  '• find duplicates — find extra copies of the same file',
  '• delete the extra copies — delete the copies you pick, to the Recycle Bin',
  '• merge the extra copies — keep one copy, move the rest into one folder',
  '• open notepad — open an installed app by name',
  '• list recent files — show the newest files I know about',
].join('\n');

export class BrainService {
  /** Turn the user's words into an action. Always returns one.
   * @param knownFolders folder names DJ knows (from the index) —
   *   a query naming one of them routes to open-folder. */
  decide(text: string, knownFolders: string[] = []): ChatAction {
    const raw = (text || '').trim();
    const low = raw.toLowerCase();
    if (!low) return { action: 'help', query: '' };

    if (low === 'help' || low.includes('what can you do') || low.includes('help me')) {
      return { action: 'help', query: '' };
    }

    if (
      low.includes('duplicat') ||
      low.includes('extra cop') ||
      low.includes('same file')
    ) {
      if (low.includes('merge')) return { action: 'duplicates', query: 'merge' };
      return {
        action: 'duplicates',
        query: low.includes('delet') ? 'delete' : '',
      };
    }

    if (low.includes('organiz')) {
      return { action: 'organize', query: parseOrganizeRangeText(low) ?? '' };
    }

    if (low.includes('summar')) {
      const query = afterWords(low, [
        'summarize this file',
        'summarise this file',
        'summarize',
        'summarise',
        'summary of',
      ]);
      return { action: 'summarize', query: query || raw };
    }

    // "open the frontend folder" / "open that related folder in
    // frontend" — the word "folder" (or "directory") means the user
    // wants a folder opened, not a file.
    const folderQuery = extractFolderQuery(raw);
    if (folderQuery !== null) {
      return { action: 'openFolder', query: folderQuery };
    }

    const known = new Set(knownFolders.map((f) => f.toLowerCase()));

    if (low.startsWith('open ')) {
      let rest = raw.slice(5).trim();
      rest = rest.replace(
        /^(something|anything|all the things|the files?|a file)\s+(about|on|related to)\s+/i,
        '',
      );
      rest = rest.replace(/^(something|anything)\s+about\s+/i, '');
      if (KNOWN_APPS.has(rest.toLowerCase())) {
        return { action: 'openApp', query: rest.toLowerCase() };
      }
      // "open frontend" — naming a folder DJ knows opens the folder.
      const folderCandidate = rest.replace(/^(the|a|an|my)\s+/i, '').trim();
      if (folderCandidate && known.has(folderCandidate.toLowerCase())) {
        return { action: 'openFolder', query: folderCandidate };
      }
      return { action: 'open', query: rest || raw };
    }

    for (const word of [
      'find ',
      'search for ',
      'search ',
      'look for ',
      'where is ',
      'where are ',
      'show me ',
    ]) {
      if (low.startsWith(word)) {
        const query = raw.slice(word.length).trim();
        const folderCandidate = query.replace(/^(the|a|an|my)\s+/i, '').trim();
        if (folderCandidate && known.has(folderCandidate.toLowerCase())) {
          return { action: 'openFolder', query: folderCandidate };
        }
        return { action: 'search', query };
      }
    }

    if (low.startsWith('list ') || low.startsWith('show ')) {
      return { action: 'list', query: raw };
    }

    // Default: the user just named a topic — search for it.
    return { action: 'search', query: raw };
  }
}

/**
 * The folder a "… folder …" message asks for, or null when the
 * message is not about a folder at all. "" means "a folder, but no
 * name given" — the chat service then lists the folders DJ knows.
 *
 *   "open the frontend folder" -> "frontend"
 *   "open AuPro frontend folder" -> "AuPro frontend"
 *   "open that related folder in frontend" -> "frontend"
 *   "find the frontend folder" -> "frontend"
 */
export function extractFolderQuery(text: string): string | null {
  const low = (text || '').toLowerCase();
  const folderIdx = low.search(/\b(?:folder|folders|directory|directories)\b/);
  if (folderIdx < 0) return null;
  // The name sits between the LAST verb before "folder" and "folder"
  // itself ("I want to find something, open the frontend folder").
  const before = text.slice(0, folderIdx);
  const verbMatches = [...before.matchAll(/\b(?:open|find|show|go to|go)\b/gi)];
  let name = '';
  if (verbMatches.length > 0) {
    const last = verbMatches[verbMatches.length - 1];
    name = cleanFolderWords(before.slice(last.index + last[0].length));
  }
  // "... folder in <project>" — the words after "in" are the project
  // the folder lives in ("open the frontend folder in AuPro").
  const inAfter = text
    .slice(folderIdx)
    .match(/\b(?:folder|directory)\b[^a-z0-9]*in\s+([a-z0-9][a-z0-9 ]*?)\s*$/i);
  const project = inAfter ? cleanFolderWords(inAfter[1]) : '';
  if (name && project) return `${name} ${project}`;
  if (name) return name;
  if (project) return project;
  return '';
}

/** Drop filler words from a folder name ("the frontend" -> "frontend"). */
function cleanFolderWords(s: string): string {
  return s
    .split(/\s+/)
    .filter(
      (w) =>
        w.length > 0 &&
        !['the', 'a', 'an', 'that', 'this', 'related', 'my', 'me'].includes(
          w.toLowerCase(),
        ),
    )
    .join(' ')
    .trim();
}

/**
 * The date range in the user's words, as a short string the
 * organizer can read back ("today", "yesterday", "last 3 days",
 * "all"), or null if no range was mentioned.
 */
export function parseOrganizeRangeText(low: string): string | null {
  if (/\b(all|everything|every file)\b/.test(low)) return 'all';
  if (low.includes('yesterday')) return 'yesterday';
  const m = low.match(/(?:last|past)\s+(\d+)\s+days?/);
  if (m) {
    const n = Math.max(1, parseInt(m[1], 10));
    return `last ${n} day${n !== 1 ? 's' : ''}`;
  }
  if (low.includes('this week') || low.includes('last week')) return 'last 7 days';
  if (low.includes('today')) return 'today';
  return null;
}

/** Parse a range string into a structured range. */
export function parseOrganizeRange(text: string): OrganizeRange | null {
  const low = (text || '').toLowerCase();
  if (/\b(all|everything|every file)\b/.test(low)) return { kind: 'all' };
  if (low.includes('yesterday')) return { kind: 'yesterday' };
  const m = low.match(/(?:last|past)\s+(\d+)\s+days?/);
  if (m) return { kind: 'lastDays', days: Math.max(1, parseInt(m[1], 10)) };
  if (low.includes('this week') || low.includes('last week')) {
    return { kind: 'lastDays', days: 7 };
  }
  if (low.includes('today')) return { kind: 'today' };
  return null;
}

/** Plain words for a range, for the preview window. */
export function rangeLabel(range: OrganizeRange): string {
  switch (range.kind) {
    case 'today':
      return 'today';
    case 'yesterday':
      return 'yesterday';
    case 'lastDays':
      return `the last ${range.days} day${range.days !== 1 ? 's' : ''}`;
    case 'all':
      return 'all files';
  }
}

function afterWords(text: string, words: string[]): string {
  for (const w of words) {
    const i = text.indexOf(w);
    if (i >= 0) {
      return text.slice(i + w.length).trim().replace(/^[:\s]+/, '');
    }
  }
  return '';
}
