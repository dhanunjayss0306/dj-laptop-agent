// DJ v3 — duplicates service. Find extra copies of the same file,
// delete the ones the user picks (to the Windows Recycle Bin, only
// after a confirmation), and merge a group (keep one copy in place,
// move the other copies into one folder the user picks).
//
// Groups by size first (only sizes with 2+ files are hashed), then
// by SHA-256 of the contents — so two files with the same size but
// different contents are NOT duplicates. Empty files and files over
// 500 MB are skipped: hashing a multi-gigabyte video just to check
// is slow, and exact copies of huge files are rare.

import * as fs from 'fs';
import * as path from 'path';

import type { DuplicateGroup } from '../../shared/types';
import { freePath } from './organizeService';
import { humanSize, sha256File } from '../utils/hashing';
import { SKIP_DIRS } from './indexService';
import { ORGANIZER_LOG, ORGANIZER_SKIP } from './organizeService';

export const MAX_DUP_MB = 500;

interface FoundFile {
  path: string;
  name: string;
  folder: string;
  mtime: string;
  size: number;
}

export class DuplicateService {
  /** Find extra copies in the given folders. Biggest waste first. */
  find(folders: string[]): DuplicateGroup[] {
    const bySize = new Map<number, string[]>();
    for (const folder of folders) {
      if (!isDirectory(folder)) continue;
      this.walk(folder, (filePath) => {
        let size = 0;
        try {
          size = fs.statSync(filePath).size;
        } catch {
          return;
        }
        if (size === 0 || size > MAX_DUP_MB * 1024 * 1024) return;
        const list = bySize.get(size) ?? [];
        list.push(filePath);
        bySize.set(size, list);
      });
    }
    const groups: DuplicateGroup[] = [];
    for (const [size, paths] of bySize) {
      if (paths.length < 2) continue;
      const byHash = new Map<string, string[]>();
      for (const p of paths) {
        const digest = sha256File(p);
        if (digest === null) continue;
        const list = byHash.get(digest) ?? [];
        list.push(p);
        byHash.set(digest, list);
      }
      for (const dupPaths of byHash.values()) {
        if (dupPaths.length < 2) continue;
        const files: FoundFile[] = [];
        const sorted = [...dupPaths].sort((a, b) => a.toLowerCase().localeCompare(b.toLowerCase()));
        for (const p of sorted) {
          let mtime = '';
          try {
            mtime = fs.statSync(p).mtime.toISOString().slice(0, 10);
          } catch {
            // leave blank
          }
          files.push({ path: p, name: path.basename(p), folder: path.dirname(p), mtime, size });
        }
        groups.push({
          id: `${size}-${files[0].path}`,
          size,
          sizeText: humanSize(size),
          wasted: size * (files.length - 1),
          files: files.map(({ path: p, name, folder, mtime }) => ({ path: p, name, folder, mtime })),
        });
      }
    }
    groups.sort((a, b) => b.wasted - a.wasted);
    return groups;
  }

  private walk(dir: string, onFile: (filePath: string) => void): void {
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        if (SKIP_DIRS.has(entry.name.toLowerCase())) continue;
        if (entry.name.startsWith('.')) continue;
        if (entry.isSymbolicLink()) continue;
        this.walk(full, onFile);
      } else if (entry.isFile()) {
        if (entry.name.startsWith('.')) continue;
        if (ORGANIZER_SKIP.has(entry.name.toLowerCase())) continue;
        onFile(full);
      }
    }
  }

  /**
   * Send files to the Recycle Bin (never permanent delete). Returns
   * what was deleted and any errors. Nothing is deleted without the
   * caller confirming first — this only does the deed. Every
   * deletion is written to _Organizer_Log.csv in logDir.
   *
   * `trashFn` is injected for tests (defaults to the real `trash`
   * package, loaded lazily so the app starts even if it is missing).
   */
  async deleteToRecycleBin(
    paths: string[],
    logDir: string,
    trashFn?: (paths: string[]) => Promise<void>,
  ): Promise<{ deleted: string[]; errors: string[]; logPath: string }> {
    const logPath = path.join(logDir, ORGANIZER_LOG);
    const deleted: string[] = [];
    const errors: string[] = [];
    const rows: string[][] = [];
    let trash: ((paths: string[]) => Promise<void>) | null = trashFn ?? null;
    if (!trash) {
      try {
        // eslint-disable-next-line @typescript-eslint/no-require-imports
        const mod = require('trash');
        trash = (mod.default ?? mod) as (paths: string[]) => Promise<void>;
      } catch {
        return {
          deleted,
          errors: [
            'The trash package is not installed, so I cannot delete safely. Run: npm install — then try again.',
          ],
          logPath,
        };
      }
    }
    const existing: string[] = [];
    for (const p of paths) {
      if (!fs.existsSync(p) || !fs.statSync(p).isFile()) {
        errors.push(`${path.basename(p)}: already gone.`);
        continue;
      }
      existing.push(p);
    }
    if (existing.length > 0) {
      try {
        await trash(existing);
        for (const p of existing) {
          deleted.push(p);
          rows.push([path.basename(p), p, 'Recycle Bin (deleted)', new Date().toISOString().slice(0, 10)]);
        }
      } catch (err) {
        errors.push(`Could not move files to the Recycle Bin: ${err}`);
      }
    }
    if (rows.length > 0) {
      const err = appendLogRows(logPath, rows);
      if (err) errors.push(err);
    }
    return { deleted, errors, logPath };
  }

  /**
   * Merge a duplicate group: keep the first copy where it is, move
   * the other copies into targetFolder (previewed and confirmed by
   * the caller first). Never overwrites (adds -1, -2, ...).
   */
  merge(
    paths: string[],
    targetFolder: string,
  ): { moved: string[]; errors: string[] } {
    const moved: string[] = [];
    const errors: string[] = [];
    if (paths.length < 2) {
      errors.push('Nothing to merge — a group needs at least two copies.');
      return { moved, errors };
    }
    fs.mkdirSync(targetFolder, { recursive: true });
    // paths[0] is the copy that stays; the rest move.
    for (const p of paths.slice(1)) {
      try {
        if (!fs.existsSync(p) || !fs.statSync(p).isFile()) {
          errors.push(`${path.basename(p)}: gone before I could move it.`);
          continue;
        }
        const dest = freePath(targetFolder, path.basename(p));
        fs.renameSync(p, dest);
        moved.push(dest);
      } catch (err) {
        errors.push(`${path.basename(p)}: ${err}`);
      }
    }
    return { moved, errors };
  }
}

function appendLogRows(logPath: string, rows: string[][]): string | null {
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

function isDirectory(p: string): boolean {
  try {
    return fs.statSync(p).isDirectory();
  } catch {
    return false;
  }
}
