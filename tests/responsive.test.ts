// DJ v3.2 tests — the window must stay responsive while DJ works.
// The v3 build was one long synchronous stretch on the main process:
// the window stopped answering Windows and the title bar said
// "(Not Responding)". These tests prove the build and the duplicate
// scan now let the event loop run other work while they run, and
// that progress messages are throttled instead of one per file.

import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { describe, expect, it } from 'vitest';

import { IndexService } from '../src/main/services/indexService';
import { EmbedderClient } from '../src/main/services/embedderClient';
import { DuplicateService } from '../src/main/services/duplicateService';
import type { IndexProgress } from '../src/shared/types';

function makeIndexer(dataDir: string, onProgress?: (p: IndexProgress) => void): IndexService {
  // Keyword-only: the embedder is never reached in these tests.
  const client = new EmbedderClient(() => false);
  return new IndexService(dataDir, client, onProgress);
}

/** A folder with `count` small readable files (flat, one folder). */
function makeManyFiles(count: number): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-many-'));
  for (let i = 0; i < count; i++) {
    fs.writeFileSync(path.join(dir, `file-${String(i).padStart(4, '0')}.txt`), `content ${i} virun travel`);
  }
  return dir;
}

describe('build: lets the event loop run while it works', () => {
  it('a timer scheduled before the build fires during the build', async () => {
    const dir = makeManyFiles(300);
    const indexer = makeIndexer(fs.mkdtempSync(path.join(os.tmpdir(), 'dj-data-')));
    let timerFired = false;
    setTimeout(() => {
      timerFired = true;
    }, 0);
    const counts = await indexer.build([dir]);
    expect(counts.files).toBe(300);
    // If the build never yielded to the event loop, the 0 ms timer
    // could only fire after the build finished.
    expect(timerFired).toBe(true);
  });

  it('progress messages are throttled, and the last one is done', async () => {
    const dir = makeManyFiles(300);
    const seen: IndexProgress[] = [];
    const indexer = makeIndexer(
      fs.mkdtempSync(path.join(os.tmpdir(), 'dj-data-')),
      (p) => {
        seen.push(p);
      },
    );
    await indexer.build([dir]);
    // One message per file would be 300+; throttling keeps it small.
    expect(seen.length).toBeLessThan(20);
    expect(seen[seen.length - 1].stage).toBe('done');
  });

  it('search results carry size and date for the Explorer row', async () => {
    const dir = makeManyFiles(3);
    const indexer = makeIndexer(fs.mkdtempSync(path.join(os.tmpdir(), 'dj-data-')));
    await indexer.build([dir]);
    const results = indexer.keywordSearch('virun', 5);
    expect(results.length).toBe(3);
    for (const r of results) {
      expect(typeof r.size).toBe('number');
      expect(r.size).toBeGreaterThan(0);
      expect(typeof r.mtime).toBe('string');
      expect(r.mtime).toMatch(/^\d{4}-\d{2}-\d{2}T/);
    }
  });
});

describe('iterFiles: the walk itself yields', () => {
  it('a timer fires while a big folder is walked', async () => {
    const dir = makeManyFiles(300);
    const indexer = makeIndexer(fs.mkdtempSync(path.join(os.tmpdir(), 'dj-data-')));
    let timerFired = false;
    setTimeout(() => {
      timerFired = true;
    }, 0);
    const found = await indexer.iterFiles([dir]);
    expect(found.length).toBe(300);
    expect(timerFired).toBe(true);
  });
});

describe('duplicates find: yields while it walks and hashes', () => {
  it('a timer fires during a duplicate scan', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-dupmany-'));
    // 30 pairs of identical files: same size, so all get hashed.
    for (let i = 0; i < 30; i++) {
      const content = `duplicate content ${i}`.padEnd(40, 'x');
      fs.writeFileSync(path.join(dir, `a-${i}.txt`), content);
      fs.writeFileSync(path.join(dir, `b-${i}.txt`), content);
    }
    const service = new DuplicateService();
    let timerFired = false;
    setTimeout(() => {
      timerFired = true;
    }, 0);
    const groups = await service.find([dir]);
    expect(groups.length).toBe(30);
    expect(timerFired).toBe(true);
  });
});
