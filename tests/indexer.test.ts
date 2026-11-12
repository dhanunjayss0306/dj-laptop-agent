// DJ v3 tests — indexer: chunking, keyword scoring, folder pruning.

import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { describe, expect, it } from 'vitest';

import { IndexService, rankFolders } from '../src/main/services/indexService';
import { EmbedderClient } from '../src/main/services/embedderClient';
import { chunkText, countOccurrences } from '../src/main/utils/text';

function makeIndexer(dir: string): IndexService {
  // The embedder is never called in these tests (keyword-only).
  const client = new EmbedderClient(() => false);
  return new IndexService(dir, client);
}

describe('chunkText: ~400 words, 50 overlap', () => {
  it('a short text is one chunk', () => {
    const chunks = chunkText('hello world, this is a short file.');
    expect(chunks.length).toBe(1);
    expect(chunks[0]).toContain('hello world');
  });
  it('1000 words become 3 chunks', () => {
    const text = Array.from({ length: 1000 }, (_, i) => `word${i}`).join(' ');
    const chunks = chunkText(text);
    expect(chunks.length).toBe(3);
    expect(chunks[0].split(/\s+/).length).toBe(400);
    expect(chunks[1].split(/\s+/).length).toBe(400);
    // The last chunk is the rest: words 700..1000 = 300 words.
    expect(chunks[2].split(/\s+/).length).toBe(300);
  });
  it('the overlap shares words between chunks', () => {
    const text = Array.from({ length: 500 }, (_, i) => `w${i}`).join(' ');
    const chunks = chunkText(text);
    expect(chunks.length).toBe(2);
    expect(chunks[0]).toContain('w399');
    expect(chunks[1]).toContain('w350');
  });
  it('empty text has no chunks', () => {
    expect(chunkText('   ')).toEqual([]);
  });
});

describe('countOccurrences', () => {
  it('counts non-overlapping hits', () => {
    expect(countOccurrences('banana banana', 'banana')).toBe(2);
    expect(countOccurrences('nothing here', 'banana')).toBe(0);
  });
});

describe('iterFiles: pruning', () => {
  it('never walks junk folders or hidden folders', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-walk-'));
    const files: Record<string, string> = {
      'real.txt': 'x',
      'sub/real2.txt': 'x',
      'node_modules/junk.txt': 'x',
      '.git/config.txt': 'x',
      '.venv/lib.txt': 'x',
      '.hidden/secret.txt': 'x',
      '__pycache__/mod.txt': 'x',
      'photo.jpg': 'x',
    };
    for (const [name, content] of Object.entries(files)) {
      const p = path.join(root, name);
      fs.mkdirSync(path.dirname(p), { recursive: true });
      fs.writeFileSync(p, content);
    }
    const indexer = makeIndexer(fs.mkdtempSync(path.join(os.tmpdir(), 'dj-data-')));
    // path.relative uses backslashes on Windows; normalize so the
    // expectation reads the same on every platform.
    const toPosix = (p: string) => p.split(path.sep).join('/');
    const found = (await indexer.iterFiles([root])).map((p) => toPosix(path.relative(root, p)));
    expect(found.sort()).toEqual(['real.txt', 'sub/real2.txt']);
  });
  it('a missing folder is skipped, not crashed on', async () => {
    const indexer = makeIndexer(fs.mkdtempSync(path.join(os.tmpdir(), 'dj-data-')));
    expect(await indexer.iterFiles(['/does/not/exist/xyz'])).toEqual([]);
  });
});

describe('keywordSearch: name beats text', () => {
  it('a word in the file name scores higher than a word in the text', async () => {
    const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-data-'));
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-kw-'));
    fs.writeFileSync(path.join(root, 'virun-pitch.txt'), 'travel tourism plans');
    fs.writeFileSync(path.join(root, 'other.txt'), 'virun virun virun');
    const indexer = makeIndexer(dataDir);
    await indexer.build([root]);
    const results = indexer.keywordSearch('virun', 5);
    expect(results.length).toBe(2);
    expect(results[0].name).toBe('virun-pitch.txt');
  });
  it('searches by meaning of words in the text', async () => {
    const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-data-'));
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-kw-'));
    fs.writeFileSync(path.join(root, 'notes.txt'), 'Chennai trip itinerary hotels');
    const indexer = makeIndexer(dataDir);
    await indexer.build([root]);
    const results = indexer.keywordSearch('chennai trip', 5);
    expect(results.length).toBe(1);
    expect(results[0].name).toBe('notes.txt');
  });
  it('an unknown word finds nothing', async () => {
    const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-data-'));
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-kw-'));
    fs.writeFileSync(path.join(root, 'notes.txt'), 'hello world');
    const indexer = makeIndexer(dataDir);
    await indexer.build([root]);
    expect(indexer.keywordSearch('zzqxwv', 5)).toEqual([]);
  });
});

describe('build: keyword-only when embeddings are unavailable', () => {
  it('builds the keyword index and reports vectorOk false', async () => {
    const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-data-'));
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-kw-'));
    fs.writeFileSync(path.join(root, 'a.txt'), 'alpha beta gamma');
    fs.writeFileSync(path.join(root, 'b.md'), '# hello\n\nsome markdown text here');
    const indexer = makeIndexer(dataDir);
    const counts = await indexer.build([root]);
    expect(counts.files).toBe(2);
    expect(counts.vectorOk).toBe(false);
    expect(counts.embedded).toBe(0);
    expect(indexer.hasIndex()).toBe(true);
    expect(indexer.indexIsStale()).toBe(false);
    // Search still works by keyword.
    const results = await indexer.search('alpha', 5);
    expect(results.length).toBe(1);
    expect(results[0].name).toBe('a.txt');
  });
  it('an empty folder builds an empty index', async () => {
    const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-data-'));
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-kw-'));
    const indexer = makeIndexer(dataDir);
    const counts = await indexer.build([root]);
    expect(counts.files).toBe(0);
    expect(indexer.hasIndex()).toBe(false);
  });
});

describe('iterFolders: folders by name, same skip rules as files', () => {
  it('records directories, skips junk and hidden folders, includes the root', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-fold-'));
    for (const dir of [
      'frontend',
      'frontend/components',
      'backend',
      'node_modules/pkg',
      '.git/objects',
      '.hidden/secret',
    ]) {
      fs.mkdirSync(path.join(root, dir), { recursive: true });
    }
    fs.writeFileSync(path.join(root, 'frontend/index.html'), '<html></html>');
    const indexer = makeIndexer(fs.mkdtempSync(path.join(os.tmpdir(), 'dj-data-')));
    const found = (await indexer.iterFolders([root]))
      .map((f) => path.relative(root, f.path).split(path.sep).join('/'))
      .sort();
    expect(found).toEqual(['', 'backend', 'frontend', 'frontend/components']);
  });
  it('a missing folder gives an empty list', async () => {
    const indexer = makeIndexer(fs.mkdtempSync(path.join(os.tmpdir(), 'dj-data-')));
    expect(await indexer.iterFolders(['/does/not/exist/xyz'])).toEqual([]);
  });
});

describe('rankFolders: exact name wins, project breaks ties', () => {
  const folders = [
    { path: '/projects/AuPro/frontend', name: 'frontend', parent: '/projects/AuPro' },
    { path: '/projects/OtherApp/frontend', name: 'frontend', parent: '/projects/OtherApp' },
    { path: '/projects/AuPro/backend', name: 'backend', parent: '/projects/AuPro' },
    { path: '/projects/AuPro', name: 'AuPro', parent: '/projects' },
  ];
  it('an exact name match comes first', () => {
    const ranked = rankFolders(folders, 'backend');
    expect(ranked[0].name).toBe('backend');
    expect(ranked).toHaveLength(1);
  });
  it('the project word picks AuPro frontend over the other frontend', () => {
    const ranked = rankFolders(folders, 'frontend AuPro');
    expect(ranked[0].path).toBe('/projects/AuPro/frontend');
  });
  it('"AuPro frontend" returns only AuPro\'s frontend, not weaker matches', () => {
    const ranked = rankFolders(folders, 'frontend AuPro');
    expect(ranked.map((f) => f.path)).toEqual(['/projects/AuPro/frontend']);
  });
  it('a bare frontend returns both frontends, AuPro first (shorter path)', () => {
    const ranked = rankFolders(folders, 'frontend');
    expect(ranked.map((f) => f.path)).toEqual([
      '/projects/AuPro/frontend',
      '/projects/OtherApp/frontend',
    ]);
  });
  it('a partial name still matches', () => {
    const ranked = rankFolders(folders, 'front');
    expect(ranked.map((f) => f.name)).toEqual(['frontend', 'frontend']);
  });
  it('an unknown name finds nothing', () => {
    expect(rankFolders(folders, 'zzqxwv')).toEqual([]);
  });
  it('an empty query finds nothing', () => {
    expect(rankFolders(folders, '')).toEqual([]);
  });
});

describe('build: folders are saved with the index', () => {
  it('build counts folders and findFolders uses them', async () => {
    const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-data-'));
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-fold-'));
    fs.mkdirSync(path.join(root, 'AuPro', 'frontend'), { recursive: true });
    fs.writeFileSync(
      path.join(root, 'AuPro', 'frontend', 'index.html'),
      '<html>AuPro site</html>',
    );
    const indexer = makeIndexer(dataDir);
    const counts = await indexer.build([root]);
    // AuPro + AuPro/frontend + the root itself.
    expect(counts.folders).toBe(3);
    expect(indexer.listFolders().map((f) => f.name).sort()).toEqual([
      'AuPro',
      path.basename(root),
      'frontend',
    ]);
    const matches = indexer.findFolders('frontend');
    expect(matches).toHaveLength(1);
    expect(matches[0].path).toBe(path.join(root, 'AuPro', 'frontend'));
    // A fresh indexer loads the folders back from disk.
    const reloaded = makeIndexer(dataDir);
    reloaded.loadFromDisk();
    expect(reloaded.listFolders()).toHaveLength(3);
  });
});
