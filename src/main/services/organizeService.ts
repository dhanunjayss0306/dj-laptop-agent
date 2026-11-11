// DJ v3 — organize service. Tidy up Downloads for a date range
// the user picks (today, yesterday, last N days, all). Preview
// first, move only, never delete, never overwrite.
//
// Rules copied from the user's own script, Organize-Downloads.ps1
// (v3): keyword folders first, then file-type folders, anything
// left goes to _Review. The script itself and its log are never
// moved.

import * as fs from 'fs';
import * as path from 'path';

import type { OrganizeMove, OrganizeRange } from '../../shared/types';
import { rangeLabel } from './brainService';

// Checked in this order. First match wins.
const KEYWORD_FOLDERS: { folder: string[]; words: string[] }[] = [
  {
    folder: ['_Private-DoNotShare'],
    words: ['credentials', 'recovery-codes', 'recovery codes', 'atlas-credentials'],
  },
  {
    folder: ['Hackathons', 'SAPSS-Vishwakarma'],
    words: [
      'sapss', 'saps', 'vishwakarma', 'smart public', 'public sanitation',
      'sanitation', 'toilet', 'pulse box', 'pulse_box',
    ],
  },
  {
    folder: ['Hackathons', 'SasyaSakhi-AgriTech'],
    words: [
      'sasyasakhi', 'soilsaathi', 'soil', 'smart farm', 'smart farming',
      'agritech', 'agri', 'crop', 'farmer', 'saiya', 'sasya',
    ],
  },
  {
    folder: ['Hackathons', 'Virun-Travel'],
    words: [
      'virun', 'yatra', 'yatrasetu', 'travel titan', 'traveltitans',
      'localmate', 'tourism', 'tourist', 'samartha', 'nataraj', 'hatra',
    ],
  },
  { folder: ['Hackathons', 'GlobalTap'], words: ['globaltap', 'global tap'] },
  { folder: ['Hackathons', 'Persona'], words: ['persona'] },
  { folder: ['Hackathons', 'Quantum'], words: ['quantum'] },
  {
    folder: ['Hackathons', 'HackerRank'],
    words: ['hackerrank', 'ghost data', 'hacerrank'],
  },
  { folder: ['Hackathons', 'VRGym'], words: ['vrgym', 'vr gym', 'vr-gym'] },
  { folder: ['Projects', 'Chaiya'], words: ['chaiya'] },
  { folder: ['Projects', 'Health'], words: ['patient', 'health concern'] },
  {
    folder: ['College'],
    words: [
      'ada', 'assignment', 'employee dataset', 'startup summit',
      'idea presentation', 'coa', 'oopj', 'os-lab', 'os lab', 'probability',
      'book list', 'exam prep', 'multiplexer', 'demultiplexer',
      'experiment', 'lab manual',
    ],
  },
];

const TYPE_FOLDERS: Record<string, string[]> = {
  Programs: ['.exe', '.msi'],
  Movies: ['.mp4', '.mkv', '.avi', '.mov', '.webm'],
  Music: ['.mp3', '.wav', '.flac', '.aac'],
  Images: ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.heic', '.svg', '.jfif', '.bmp'],
  Documents: ['.pdf', '.docx', '.doc', '.txt', '.md'],
  Spreadsheets: ['.xlsx', '.xls', '.csv'],
  Presentations: ['.pptx', '.ppt'],
  Code: ['.py', '.js', '.ts', '.jsx', '.tsx', '.html', '.css', '.json', '.ipynb', '.dxf'],
  Archives: ['.zip', '.rar', '.7z', '.tar', '.gz'],
};

// Files the organizer never touches.
export const ORGANIZER_SKIP = new Set([
  'organize-downloads.ps1',
  '_organizer_log.csv',
  'downloads-preview.csv',
]);

export const ORGANIZER_LOG = '_Organizer_Log.csv';

/** Where one file goes, using the same rules as the .ps1 script. */
export function destinationFolder(name: string): string[] {
  const lower = name.toLowerCase();
  if (lower.endsWith('.env')) return ['_Private-DoNotShare'];
  for (const { folder, words } of KEYWORD_FOLDERS) {
    for (const word of words) {
      if (lower.includes(word)) return folder;
    }
  }
  if (lower.includes('whatsapp image')) return ['Images', 'WhatsApp'];
  if (lower.includes('chatgpt image')) return ['Images', 'ChatGPT'];
  if (lower.includes('screenshot')) return ['Images'];
  const ext = path.extname(name).toLowerCase();
  for (const [folder, exts] of Object.entries(TYPE_FOLDERS)) {
    if (exts.includes(ext)) return [folder];
  }
  return ['_Review'];
}

/** A destination path that never overwrites: adds -1, -2, ... */
export function freePath(destFolder: string, name: string): string {
  let dest = path.join(destFolder, name);
  if (!fs.existsSync(dest)) return dest;
  const ext = path.extname(name);
  const stem = path.basename(name, ext);
  let n = 1;
  for (;;) {
    const cand = path.join(destFolder, `${stem}-${n}${ext}`);
    if (!fs.existsSync(cand)) return cand;
    n += 1;
  }
}

function rangeDates(range: OrganizeRange): Set<string> | null {
  const today = new Date();
  const key = (d: Date): string => d.toISOString().slice(0, 10);
  const addDays = (d: Date, n: number): Date => {
    const c = new Date(d);
    c.setDate(c.getDate() + n);
    return c;
  };
  switch (range.kind) {
    case 'today':
      return new Set([key(today)]);
    case 'yesterday':
      return new Set([key(addDays(today, -1))]);
    case 'lastDays': {
      // "last N days" means today and the N days before it, so a
      // file from exactly N days ago is still included.
      const out = new Set<string>();
      for (let i = 0; i <= range.days; i++) out.add(key(addDays(today, -i)));
      return out;
    }
    case 'all':
      return null;
  }
}

export function organizeLabel(range: OrganizeRange): string {
  return rangeLabel(range);
}

function appendLog(logPath: string, rows: string[][]): string | null {
  try {
    const writeHeader = !fs.existsSync(logPath);
    const lines: string[] = [];
    if (writeHeader) lines.push('Name,OldPath,NewPath,Date');
    for (const row of rows) {
      lines.push(row.map((c) => `"${String(c).replace(/"/g, '""')}"`).join(','));
    }
    fs.appendFileSync(logPath, lines.join('\n') + '\n', 'utf-8');
    return null;
  } catch (err) {
    return `Could not write the log: ${err}`;
  }
}

export class OrganizeService {
  /** Plan a Downloads tidy-up for a date range. Moves NOTHING.
   * Only files directly in Downloads in that range. */
  plan(downloadsDir: string, range: OrganizeRange): OrganizeMove[] {
    if (!fs.existsSync(downloadsDir)) return [];
    const dates = rangeDates(range);
    const plan: OrganizeMove[] = [];
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(downloadsDir, { withFileTypes: true });
    } catch {
      return [];
    }
    const names = entries
      .filter((e) => e.isFile())
      .map((e) => e.name)
      .sort((a, b) => a.localeCompare(b));
    for (const name of names) {
      if (ORGANIZER_SKIP.has(name.toLowerCase())) continue;
      const full = path.join(downloadsDir, name);
      let mtime: Date;
      try {
        mtime = fs.statSync(full).mtime;
      } catch {
        continue;
      }
      if (dates !== null && !dates.has(mtime.toISOString().slice(0, 10))) continue;
      const folderParts = destinationFolder(name);
      const destFolder = path.join(downloadsDir, ...folderParts);
      const dest = freePath(destFolder, name);
      plan.push({
        name,
        old: full,
        new: dest,
        folder: folderParts.join(path.sep),
      });
    }
    return plan;
  }

  /** Carry out a plan. Move only, never delete, never overwrite.
   * Every move is written to _Organizer_Log.csv in Downloads. */
  apply(
    plan: OrganizeMove[],
    downloadsDir: string,
  ): { moved: OrganizeMove[]; errors: string[]; logPath: string } {
    const moved: OrganizeMove[] = [];
    const errors: string[] = [];
    for (const item of plan) {
      try {
        if (!fs.existsSync(item.old) || !fs.statSync(item.old).isFile()) {
          errors.push(`${item.name}: gone before I could move it.`);
          continue;
        }
        const destDir = path.dirname(item.new);
        fs.mkdirSync(destDir, { recursive: true });
        // Re-check the free path at move time (never overwrite).
        const dest = freePath(destDir, path.basename(item.new));
        fs.renameSync(item.old, dest);
        moved.push({ ...item, new: dest });
      } catch (err) {
        errors.push(`${item.name}: ${err}`);
      }
    }
    const logPath = path.join(downloadsDir, ORGANIZER_LOG);
    if (moved.length > 0) {
      const err = appendLog(
        logPath,
        moved.map((m) => [m.name, m.old, m.new, new Date().toISOString().slice(0, 10)]),
      );
      if (err) errors.push(err);
    }
    return { moved, errors, logPath };
  }
}
