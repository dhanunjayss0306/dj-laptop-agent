// DJ v5.5 tests — fast incremental index, background build,
// perfect PDF text. All file work happens in temp folders;
// no real model, no network, no Electron window.

import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { describe, expect, it, vi } from 'vitest';

import { IndexService, withTimeout } from '../src/main/services/indexService';
import { EmbedderClient } from '../src/main/services/embedderClient';
import { readFileContent } from '../src/main/services/fileReader';
import { chunkPdfText } from '../src/main/utils/text';

/**
 * pdf-parse is mocked for the PDF-status tests, with the parse
 * result controlled per file by name. WHY A MOCK: the pdf-parse
 * version bundled here (1.1.4, pdf.js 1.10.100 from 2017) rejects
 * small PDFs produced by some real generators — verified in this
 * environment against fpdf2 output, LibreOffice HTML export, and
 * the SasyaSakhi brief PDF, all "bad XRef entry", while real-world
 * PDFs from other producers parse fine (verified: the Indian Soil
 * Health Card sample and the 23-page master skill pack). The mock
 * stands in for the library so these tests prove DJ's own logic
 * (status mapping, page-aware chunking, honest notes) instead of
 * the library's parser quirks. The production code still calls
 * the real pdf-parse; a PDF it rejects comes back as 'unreadable'
 * and is skipped with its name logged. The mock is a callable
 * function because fileReader does require('pdf-parse') and calls
 * the result directly (pdf-parse's export IS the function).
 * (vi.hoisted is needed because vi.mock factories run before the
 * test file's own top-level code.)
 */
const pdfMockState = vi.hoisted(() => ({
  results: new Map<string, { text: string; numpages: number }>(),
  currentName: '',
}));
vi.mock('pdf-parse', () => ({
  default: async (buf: Buffer) => {
    void buf;
    const hit = pdfMockState.results.get(pdfMockState.currentName);
    if (!hit) throw new Error('no mocked pdf-parse result for ' + pdfMockState.currentName);
    return hit;
  },
}));

function mockPdfFor(fileName: string, result: { text: string; numpages: number }): void {
  pdfMockState.results.set(fileName, result);
  pdfMockState.currentName = fileName;
}

/** An embedder that answers instantly and counts how many embed
 *  calls it got (0 = full reuse). Its vectors depend on the text,
 *  so different files score differently — the way a real
 *  embedding model behaves. */
function makeFakeEmbedder(): { client: EmbedderClient; calls: () => number } {
  const client = new EmbedderClient(() => true);
  let calls = 0;
  client.embedTexts = (async (texts: string[]) => {
    calls += 1;
    // A successful embed means the model is ready — the real
    // client sets state='ready' in onResponse; the stub does it here.
    client.state = 'ready';
    return texts.map((t) => {
      const v = new Array(768).fill(0);
      for (let i = 0; i < t.length; i++) v[t.charCodeAt(i) % 768] += 1;
      return v;
    });
  }) as EmbedderClient['embedTexts'];
  return { client, calls: () => calls };
}

function makeIndexer(dir: string, client: EmbedderClient): IndexService {
  return new IndexService(dir, client);
}

function writeFile(root: string, name: string, content: string | Buffer): string {
  const p = path.join(root, name);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, content);
  return p;
}

describe('withTimeout', () => {
  it('a promise that never settles is abandoned, fast', async () => {
    const start = Date.now();
    await expect(
      withTimeout(new Promise(() => undefined), 50),
    ).rejects.toThrow(/timed out/);
    expect(Date.now() - start).toBeLessThan(500);
  });

  it('a fast promise resolves normally', async () => {
    await expect(withTimeout(Promise.resolve(7), 1000)).resolves.toBe(7);
  });
});

describe('incremental rebuild', () => {
  it('reuses unchanged files with zero re-embeds, then only the changed file', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-v55-root-'));
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-v55-idx-'));
    writeFile(root, 'a.txt', 'alpha beta gamma delta');
    writeFile(root, 'b.txt', 'one two three four five six seven');
    const { client, calls } = makeFakeEmbedder();
    const indexer = makeIndexer(dir, client);
    indexer.loadFromDisk();

    const first = await indexer.build([root]);
    expect(first.files).toBe(2);
    expect(first.reused).toBe(0);
    const firstCalls = calls();
    expect(firstCalls).toBeGreaterThan(0);

    // Nothing changed: a full rebuild must not re-embed anything.
    const second = await indexer.build([root]);
    expect(second.files).toBe(2);
    expect(second.reused).toBe(2);
    expect(second.new).toBe(0);
    expect(calls()).toBe(firstCalls);

    // Only b.txt changed: only it is re-read and re-embedded.
    writeFile(root, 'b.txt', 'eight nine ten eleven twelve');
    const third = await indexer.build([root]);
    expect(third.files).toBe(2);
    expect(third.reused).toBe(1);
    expect(third.new).toBe(1);
    expect(calls()).toBeGreaterThan(firstCalls);

    // Deleted files drop out: a.txt is gone, so the keyword index
    // must no longer match it. (Vector search has no score floor,
    // so it can still return a weak best match — the keyword
    // index is the honest check for "is this file still here".)
    fs.unlinkSync(path.join(root, 'a.txt'));
    const fourth = await indexer.build([root]);
    expect(fourth.files).toBe(1);
    expect(fourth.removed).toBe(1);
    expect(indexer.keywordSearch('alpha', 8)).toEqual([]);
    expect(indexer.keywordSearch('eight', 8)).toHaveLength(1);
  });

  it('reuse survives a restart (size + mtime saved on disk)', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-v55-root-'));
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-v55-idx-'));
    writeFile(root, 'a.txt', 'alpha beta gamma delta');
    const { client, calls } = makeFakeEmbedder();
    const first = makeIndexer(dir, client);
    first.loadFromDisk();
    await first.build([root]);
    const firstCalls = calls();

    // A brand-new IndexService over the same saved folder reuses
    // the file without re-embedding it.
    const second = makeIndexer(dir, client);
    second.loadFromDisk();
    const counts = await second.build([root]);
    expect(counts.files).toBe(1);
    expect(counts.reused).toBe(1);
    expect(calls()).toBe(firstCalls);
  });
});

describe('slow / broken files are skipped, build continues', () => {
  it('a corrupt PDF and a binary .txt do not stop the build', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-v55-root-'));
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-v55-idx-'));
    writeFile(root, 'good.txt', 'hello world, this file is fine');
    // Garbage bytes with a .pdf name: the parse fails (here the
    // mock has no result for it, exactly like a real pdf-parse
    // failure), so the build must skip it (status 'unreadable')
    // and keep going.
    writeFile(root, 'broken.pdf', Buffer.from([0x25, 0x50, 0x44, 0x46, 0x00, 0xff, 0xfe, 0x12, 0x99]));
    // A .txt full of NUL bytes: binary sniff skips it fast.
    writeFile(root, 'binary.txt', Buffer.from([0x00, 0x01, 0x02, 0x03, 0x00, 0xff]));
    const { client } = makeFakeEmbedder();
    const indexer = makeIndexer(dir, client);
    indexer.loadFromDisk();

    const counts = await indexer.build([root]);
    expect(counts.files).toBe(1);
    // Unreadable / too-slow files count as errors (not 'skipped',
    // which is for files that read fine but hold no text); their
    // names are logged and the build keeps going.
    expect(counts.errors).toBe(2);
    expect(counts.skippedNames).toContain('broken.pdf');
    expect(counts.skippedNames).toContain('binary.txt');
    expect(indexer.keywordSearch('hello', 8)).toHaveLength(1);
  });
});

describe('PDF text, honestly', () => {
  it('a text PDF reads with its page number', async () => {
    const p = writeFile(os.tmpdir(), 'dj-v55-text.pdf', Buffer.from('%PDF-1.4 fake bytes'));
    mockPdfFor('dj-v55-text.pdf', { text: 'Hello PDF world', numpages: 3 });
    const content = await readFileContent(p);
    expect(content.status).toBe('ok');
    expect(content.pages).toBe(3);
    expect(content.text).toContain('Hello PDF world');
  });

  it('a scanned PDF (pages, no text) is reported as no-text', async () => {
    const p = writeFile(os.tmpdir(), 'dj-v55-scanned.pdf', Buffer.from('%PDF-1.4 fake bytes'));
    mockPdfFor('dj-v55-scanned.pdf', { text: '   \n ', numpages: 1 });
    const content = await readFileContent(p);
    expect(content.status).toBe('no-text');
    expect(content.pages).toBe(1);
    expect(content.text).toBe('');
  });

  it('a scanned PDF is indexed by name and the result says so', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-v55-root-'));
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-v55-idx-'));
    writeFile(root, 'notes.txt', 'ordinary notes here');
    writeFile(root, 'scanned-report.pdf', Buffer.from('%PDF-1.4 fake bytes'));
    mockPdfFor('scanned-report.pdf', { text: '', numpages: 2 });
    const { client } = makeFakeEmbedder();
    const indexer = makeIndexer(dir, client);
    indexer.loadFromDisk();

    const counts = await indexer.build([root]);
    expect(counts.files).toBe(2);
    const results = await indexer.search('scanned-report', 8);
    expect(results).toHaveLength(1);
    expect(results[0].name).toBe('scanned-report.pdf');
    expect(results[0].note).toMatch(/no readable text|scanned image/);
  });

  it('page-aware chunks never straddle a page break', () => {
    // Real pdf-parse output marks pages with a form feed (see
    // fileReader's pagerender); chunkPdfText splits on it and tags
    // each chunk with its page number.
    const text = 'Alpha one\fBeta two\fGamma three';
    const chunks = chunkPdfText(text);
    expect(chunks.length).toBe(3);
    expect(chunks[0]).toBe('[page 1] Alpha one');
    expect(chunks[1]).toBe('[page 2] Beta two');
    expect(chunks[2]).toBe('[page 3] Gamma three');
    // A long single page still splits (400 words per chunk), and a
    // long page keeps its page marker on every piece.
    const long = 'word '.repeat(500) + '\f' + 'other '.repeat(10);
    const split = chunkPdfText(long);
    expect(split.length).toBe(3);
    expect(split[0].startsWith('[page 1]')).toBe(true);
    expect(split[1].startsWith('[page 1]')).toBe(true);
    expect(split[2]).toBe('[page 2] ' + 'other '.repeat(10).trim());
  });
});

describe('search fast path', () => {
  it('keyword results come back at once when the model is unavailable', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-v55-root-'));
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-v55-idx-'));
    // The match is by TEXT, not by file name (a name match wins
    // outright with no note — that path is covered by the scanned
    // PDF test above), so the meaning-search note must appear.
    writeFile(root, 'notes.txt', 'alpha beta gamma delta');
    writeFile(root, 'other.txt', 'something completely different');
    // Embedder that is never ready (model not loaded).
    const client = new EmbedderClient(() => false);
    const indexer = makeIndexer(dir, client);
    indexer.loadFromDisk();
    await indexer.build([root]);

    const start = Date.now();
    const results = await indexer.search('alpha', 8);
    expect(Date.now() - start).toBeLessThan(1000);
    expect(results.length).toBeGreaterThanOrEqual(1);
    expect(results[0].name).toBe('notes.txt');
    // The user is told plainly that meaning search is not ready.
    expect(results[0].note ?? '').toMatch(/meaning search/i);
  });

  it('a hanging embed request times out fast for queries', async () => {
    // The renderer accepts the request but never answers: the
    // query path must give up in ~8 seconds, not the 5-minute
    // build timeout, and must not poison the embedder.
    const client = new EmbedderClient(() => true);
    const start = Date.now();
    const out = await client.embedQuery('hello world');
    expect(out).toBeNull();
    const took = Date.now() - start;
    expect(took).toBeGreaterThanOrEqual(7500);
    expect(took).toBeLessThan(12_000);
    expect(client.state).toBe('loading');
  }, 15_000);
});
