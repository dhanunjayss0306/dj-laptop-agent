// DJ v3 — keyword index repository. A plain JSON file of file names
// and file text, saved as keyword_index.json. Used when embeddings
// are not available, so search still works.

import * as fs from 'fs';
import * as path from 'path';

import type { IndexedFile, IndexedFolder } from '../domain/types';

const FILE_NAME = 'keyword_index.json';

export interface KeywordIndexFile {
  version: number;
  files: IndexedFile[];
  /** Folders recorded at index time (v3.1+; missing in older indexes). */
  folders: IndexedFolder[];
}

export class KeywordIndexRepository {
  constructor(private readonly dataDir: string) {}

  load(): KeywordIndexFile {
    const p = path.join(this.dataDir, FILE_NAME);
    try {
      if (fs.existsSync(p)) {
        const parsed = JSON.parse(fs.readFileSync(p, 'utf-8')) as KeywordIndexFile;
        // Older indexes (v3.0) have no folders list yet.
        if (Array.isArray(parsed.files)) {
          return {
            version: parsed.version ?? 1,
            files: parsed.files,
            folders: Array.isArray(parsed.folders) ? parsed.folders : [],
          };
        }
      }
    } catch {
      // Corrupt index: start empty.
    }
    return { version: 1, files: [], folders: [] };
  }

  save(index: KeywordIndexFile): void {
    fs.mkdirSync(this.dataDir, { recursive: true });
    fs.writeFileSync(
      path.join(this.dataDir, FILE_NAME),
      JSON.stringify(index),
      'utf-8',
    );
  }
}
