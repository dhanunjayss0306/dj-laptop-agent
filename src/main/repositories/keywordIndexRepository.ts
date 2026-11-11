// DJ v3 — keyword index repository. A plain JSON file of file names
// and file text, saved as keyword_index.json. Used when embeddings
// are not available, so search still works.

import * as fs from 'fs';
import * as path from 'path';

import type { IndexedFile } from '../domain/types';

const FILE_NAME = 'keyword_index.json';

export interface KeywordIndexFile {
  version: number;
  files: IndexedFile[];
}

export class KeywordIndexRepository {
  constructor(private readonly dataDir: string) {}

  load(): KeywordIndexFile {
    const p = path.join(this.dataDir, FILE_NAME);
    try {
      if (fs.existsSync(p)) {
        const parsed = JSON.parse(fs.readFileSync(p, 'utf-8')) as KeywordIndexFile;
        if (Array.isArray(parsed.files)) return parsed;
      }
    } catch {
      // Corrupt index: start empty.
    }
    return { version: 1, files: [] };
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
