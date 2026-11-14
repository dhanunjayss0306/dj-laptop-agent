// DJ v3 — index service. DJ's private search engine over the
// user's files. Two parts, working together:
//
//   1. Meaning search: each file is split into chunks, each chunk is
//      turned into an embedding by the tiny local model (inside the
//      app, no server), and stored in the local vector store. A
//      search for "travel and tourism" then finds files about travel
//      even if those exact words are not in the file name.
//   2. Keyword search (always available): a plain index of file
//      names and file text. Used when embeddings are not available,
//      so search still works.
//
// Nothing leaves the laptop: the vector store and the keyword index
// are files on this machine only.

import * as fs from 'fs';
import * as path from 'path';

import type { IndexCounts, IndexProgress, SearchResult } from '../../shared/types';
import type { IndexedFile, IndexedFolder, StoredVector } from '../domain/types';
import { KeywordIndexRepository } from '../repositories/keywordIndexRepository';
import { EMBED_FORMAT_VERSION } from '../repositories/vectorRepository';
import { fileId } from '../utils/hashing';
import { chunkPdfText, chunkText, CHUNK_VERSION, countOccurrences, snippet } from '../utils/text';
import type { EmbedderClient } from './embedderClient';
import { readFileContent, readText, type ReadStatus } from './fileReader';
import { VectorStore } from './vectorStore';

// File types DJ can read text from.
export const READABLE_EXTS = new Set([
  '.txt', '.md', '.py', '.js', '.ts', '.jsx', '.tsx', '.html', '.css',
  '.json', '.csv', '.log', '.pdf', '.docx', '.pptx', '.xlsx',
]);

// Folders DJ never walks into, even inside the folders the user picked.
export const SKIP_DIRS = new Set([
  'appdata', '.git', 'node_modules', '__pycache__', '.venv', 'venv',
  '.cache', '.antigravity', 'dj_data', '$recycle.bin',
  'system volume information',
]);

// Files bigger than this are skipped (too big to embed usefully).
export const MAX_FILE_MB = 20;

// How much of a file's text the keyword index keeps (first 12,000 chars).
export const KEYWORD_TEXT_LIMIT = 12000;

const EMBED_BATCH = 5;

// How often progress may be sent to the window (ms). The build
// used to send one progress message per file — thousands of IPC
// messages and React re-renders — which helped freeze the window.
const PROGRESS_MIN_MS = 150;

// How long one file may take to read before it is skipped: a
// corrupt PDF can hang pdf-parse, and one bad file must never
// stall the whole build. The file is logged and counted, and the
// build keeps going.
const READ_TIMEOUT_MS = 15_000;

// How many skipped file names the build report keeps (first 20).
const SKIPPED_NAMES_MAX = 20;

// Plain words attached to keyword results when meaning search
// could not run (same wording as chatService.meaningNote).
const MEANING_LOADING_NOTE =
  'Meaning search is still loading — these are keyword matches for now.';
const MEANING_UNAVAILABLE_NOTE =
  'Meaning search is unavailable right now — these are keyword matches.';

/** Race a promise against a clock. The slow work is abandoned —
 *  for pdf-parse that means the parse keeps running in the
 *  background, but the build no longer waits on it. */
export function withTimeout<T>(p: Promise<T>, ms: number): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  const timeout = new Promise<T>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`timed out after ${ms} ms`)), ms);
  });
  return Promise.race([p, timeout]).finally(() => {
    if (timer !== undefined) clearTimeout(timer);
  });
}

/** Plain-language note for a file with no readable text. */
function noTextNote(filePath: string, status: ReadStatus): string {
  const name = path.basename(filePath);
  if (status === 'no-text') {
    return `${name} has no readable text inside — scanned image, needs OCR.`;
  }
  if (status === 'encrypted') {
    return `${name} is locked (encrypted) — open it with its password first.`;
  }
  return '';
}

// How often the build lets the main-process event loop run other
// work (ms). Without this the build is one long stretch of
// synchronous work and microtasks, the window stops answering
// Windows, and the title bar says "(Not Responding)".
const YIELD_EVERY_MS = 100;

// How many directory entries the walk reads before yielding.
const WALK_YIELD_EVERY = 200;

/** Let the event loop run pending work (window messages, IPC). */
function yieldToEventLoop(): Promise<void> {
  return new Promise<void>((resolve) => setImmediate(resolve));
}

/** Size + last-modified date of a file, for Explorer-style rows. */
export function statMeta(filePath: string): { size?: number; mtime?: string } {
  try {
    const st = fs.statSync(filePath);
    return { size: st.size, mtime: st.mtime.toISOString() };
  } catch {
    return {};
  }
}

export type ProgressCallback = (p: IndexProgress) => void;

/** One file found by the walk, with the size + last-modified time
 *  a rebuild needs to tell "unchanged" from "changed". */
export interface WalkEntry {
  path: string;
  size: number;
  mtimeMs: number;
}

/** What meaning search did on the last search — the chat uses
 *  this to say plainly when results are keyword-only because the
 *  model is still loading or unavailable. */
export type MeaningStatus = 'ready' | 'loading' | 'unavailable' | 'not-indexed';

export class IndexService {
  private readonly keywordRepo: KeywordIndexRepository;
  private readonly store: VectorStore;
  private keywordFiles: IndexedFile[] = [];
  private keywordFolders: IndexedFolder[] = [];

  /** True when the vector store has usable vectors. */
  vectorOk = false;

  /** What meaning search did on the last search. */
  lastMeaning: MeaningStatus = 'not-indexed';

  /** Last time a progress message was sent (ms since epoch). */
  private lastProgressAt = 0;

  /** Last time the build yielded to the event loop (ms since epoch). */
  private lastYieldAt = 0;

  constructor(
    private readonly dataDir: string,
    private readonly embedder: EmbedderClient,
    private readonly onProgress?: ProgressCallback,
  ) {
    this.keywordRepo = new KeywordIndexRepository(dataDir);
    this.store = new VectorStore(dataDir);
  }

  // -- lifecycle ------------------------------------------------------

  /** Load whatever index is already on disk (app restart). */
  loadFromDisk(): void {
    const saved = this.keywordRepo.load();
    this.keywordFiles = saved.files;
    this.keywordFolders = saved.folders ?? [];
    this.vectorOk = this.store.loadFromDisk();
  }

  /** True when an index exists at all (keyword files or vectors). */
  hasIndex(): boolean {
    return this.keywordFiles.length > 0 || this.store.hasStoredVectors();
  }

  /**
   * True if vectors exist but were built with an old embedding
   * format — they no longer match how new texts are embedded, so
   * meaning search would be wrong. A keyword-only index (no vectors
   * at all) is not stale: it is a fresh index that simply has no
   * vectors yet.
   */
  indexIsStale(): boolean {
    if (!this.store.hasStoredVectors()) return false;
    return this.store.storedFormat() !== EMBED_FORMAT_VERSION;
  }

  status(): { filesIndexed: number; foldersIndexed: number; vectorOk: boolean } {
    return {
      filesIndexed: this.keywordFiles.length,
      foldersIndexed: this.keywordFolders.length,
      vectorOk: this.vectorOk,
    };
  }

  /** Every folder DJ knows about, by name (for "open the frontend folder"). */
  listFolders(): IndexedFolder[] {
    return [...this.keywordFolders].sort((a, b) => a.name.localeCompare(b.name));
  }

  /** Best-matching folders for a query, best first (empty when none). */
  findFolders(query: string): IndexedFolder[] {
    return rankFolders(this.keywordFolders, query);
  }

  // -- walking ----------------------------------------------------------

  private progress(stage: IndexProgress['stage'], done: number, total: number, message: string): void {
    // Throttled: at most one progress message per PROGRESS_MIN_MS,
    // so the window is not flooded with thousands of IPC messages
    // and re-renders. The final 'done' message always goes out.
    const now = Date.now();
    if (stage !== 'done' && now - this.lastProgressAt < PROGRESS_MIN_MS) return;
    this.lastProgressAt = now;
    try {
      this.onProgress?.({ stage, done, total, message });
    } catch {
      // Progress display must never break the build.
    }
  }

  /** Yield to the event loop when it has been a while, so the window
   *  keeps answering Windows while a long job runs. */
  private async yieldSometimes(): Promise<void> {
    const now = Date.now();
    if (now - this.lastYieldAt >= YIELD_EVERY_MS) {
      this.lastYieldAt = now;
      await yieldToEventLoop();
    }
  }

  /**
   * All readable files under the given folders, skipping junk. The
   * walk prunes junk folders while it walks — it never descends into
   * them at all. Progress is reported as the walk goes (once per
   * folder, then every 200 files found), and the same lines are
   * printed to the console. One bad folder (permission error,
   * OneDrive hiccup, broken link) is skipped with a note instead of
   * stalling the whole build, and directory symlinks/junctions are
   * never followed.
   *
   * Async, and it yields to the event loop as it goes: the walk
   * used to be one long synchronous stretch that froze the window
   * ("Not Responding") on a big folder tree.
   *
   * Each entry carries size + last-modified time, so a rebuild can
   * tell an unchanged file from a changed one without reading it.
   */
  async iterFileEntries(folders: string[]): Promise<WalkEntry[]> {
    const found: WalkEntry[] = [];
    const seen = new Set<string>();
    for (const folder of folders) {
      if (!isDirectory(folder)) {
        console.log(`DJ: skipping ${folder} (not a folder)`);
        continue;
      }
      const display = path.basename(folder) || folder;
      const foundBefore = found.length;
      console.log(`DJ: scanning ${display} ...`);
      this.progress('scan', found.length, 0, `Scanning ${display}...`);
      try {
        await this.walkDir(folder, (filePath, size, mtimeMs) => {
          found.push({ path: filePath, size, mtimeMs });
          if (found.length % 200 === 0) {
            const msg = `Scanning ${display}... ${found.length} files found`;
            console.log(`DJ: ${msg}`);
            this.progress('scan', found.length, 0, msg);
          }
        }, seen);
      } catch (err) {
        console.log(`DJ: could not look inside ${display}: ${err} (skipped)`);
        continue;
      }
      console.log(`DJ: scanned ${display}: ${found.length - foundBefore} files found`);
    }
    console.log(`DJ: scan done: ${found.length} readable files in total`);
    return found;
  }

  /** Paths only, for callers that do not need sizes. */
  async iterFiles(folders: string[]): Promise<string[]> {
    return (await this.iterFileEntries(folders)).map((e) => e.path);
  }

  private async walkDir(
    dir: string,
    onFile: (filePath: string, size: number, mtimeMs: number) => void,
    seen: Set<string>,
    onDir?: (dirPath: string) => void,
  ): Promise<void> {
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch (err) {
      console.log(`DJ: could not read a folder: ${err} (skipped)`);
      return;
    }
    let visited = 0;
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        // Prune junk folders here: never descend into them.
        if (SKIP_DIRS.has(entry.name.toLowerCase())) continue;
        if (entry.name.startsWith('.')) continue;
        if (entry.isSymbolicLink()) continue;
        onDir?.(full);
        await this.walkDir(full, onFile, seen, onDir);
      } else if (entry.isFile()) {
        if (entry.name.startsWith('.')) continue;
        if (!READABLE_EXTS.has(path.extname(entry.name).toLowerCase())) continue;
        let size = 0;
        let mtimeMs = 0;
        try {
          const st = fs.statSync(full);
          size = st.size;
          mtimeMs = st.mtimeMs;
        } catch {
          continue;
        }
        if (size > MAX_FILE_MB * 1024 * 1024) continue;
        let key: string;
        try {
          key = fs.realpathSync(full);
        } catch {
          key = full;
        }
        if (seen.has(key)) continue;
        seen.add(key);
        onFile(full, size, mtimeMs);
      }
      // Anything else (sockets, fifos, ...): skip.
      visited += 1;
      if (visited % WALK_YIELD_EVERY === 0) {
        await yieldToEventLoop();
      }
    }
  }

  // -- build ------------------------------------------------------------

  /**
   * Every directory under the given folders, by name — so DJ can open
   * a folder ("open the frontend folder"). Same skip rules as files:
   * junk and hidden folders are never recorded. The roots themselves
   * count too (so "open AuPro" works when AuPro is an indexed folder).
   * Async, yields as it walks, like iterFiles.
   */
  async iterFolders(folders: string[]): Promise<IndexedFolder[]> {
    const found: IndexedFolder[] = [];
    const seen = new Set<string>();
    const record = (dirPath: string): void => {
      let key: string;
      try {
        key = fs.realpathSync(dirPath);
      } catch {
        key = dirPath;
      }
      if (seen.has(key)) return;
      seen.add(key);
      found.push({
        path: dirPath,
        name: path.basename(dirPath) || dirPath,
        parent: path.dirname(dirPath),
      });
    };
    for (const folder of folders) {
      if (!isDirectory(folder)) continue;
      record(folder);
      try {
        await this.walkDir(
          folder,
          () => {},
          new Set<string>(),
          (dirPath) => record(dirPath),
        );
      } catch (err) {
        console.log(`DJ: could not list folders in ${folder}: ${err} (skipped)`);
        continue;
      }
    }
    return found;
  }

  /**
   * Build (or rebuild) the whole index. Returns counts.
   *
   * Incremental (v5.5): a file whose size + last-modified time
   * match the saved index is NOT read or re-embedded — its keyword
   * entry and its vectors are reused as-is. Only new or changed
   * files are read and embedded, and files that are gone drop out.
   * A normal rebuild after adding a few files is therefore seconds,
   * not a full re-read of 60,000 files.
   *
   * Two phases: (1) read the changed files and save the keyword
   * index at once, so keyword search works immediately; (2) embed
   * the new chunks in small batches, so the window keeps answering
   * while the model works. If the embedder is down, phase 1 still
   * lands and the stored vectors of reused files are kept — the
   * build never wipes good vectors because the model was off.
   *
   * One slow or broken file cannot stall the build: each read has
   * a 15 s timeout, the file is logged and counted, and the build
   * keeps going. A scanned PDF (no extractable text) and a locked
   * PDF are indexed by name with an honest note, never silently
   * dropped.
   */
  async build(folders: string[]): Promise<IndexCounts> {
    const counts: IndexCounts = {
      files: 0,
      folders: 0,
      chunks: 0,
      embedded: 0,
      keywordOnly: 0,
      skipped: 0,
      errors: 0,
      seconds: 0,
      vectorOk: false,
      reused: 0,
      new: 0,
      removed: 0,
      skippedNames: [],
    };
    const t0 = Date.now();
    this.lastProgressAt = 0;
    this.lastYieldAt = Date.now();
    this.progress('scan', 0, 1, 'Looking through your folders...');
    const entries = await this.iterFileEntries(folders);
    const total = Math.max(entries.length, 1);

    // -- partition: reuse what did not change -----------------------
    const savedByPath = new Map(this.keywordFiles.map((f) => [f.path, f]));
    const entryByPath = new Map(entries.map((e) => [e.path, e]));
    for (const p of savedByPath.keys()) {
      if (!entryByPath.has(p)) counts.removed = (counts.removed ?? 0) + 1;
    }
    // Vectors the last build stored, grouped by file, for reuse.
    const storedRowsByPath = new Map<string, StoredVector[]>();
    for (const row of this.store.getRows()) {
      const list = storedRowsByPath.get(row.path) ?? [];
      list.push(row);
      storedRowsByPath.set(row.path, list);
    }
    // Chunking changed for PDFs in v5.5 (page-aware). An old store
    // has no chunk version, so its PDF rows are re-embedded once;
    // every other file's rows are reused as-is.
    const chunkOk = this.store.storedChunkVersion === CHUNK_VERSION;

    const keywordFiles: IndexedFile[] = [];
    const reusedRows: StoredVector[] = [];
    const toRead: WalkEntry[] = [];
    for (const e of entries) {
      const saved = savedByPath.get(e.path);
      const ext = path.extname(e.path).toLowerCase();
      const unchanged =
        saved !== undefined && saved.size === e.size && saved.mtimeMs === e.mtimeMs;
      const needsRechunk = !chunkOk && ext === '.pdf';
      if (unchanged && !needsRechunk) {
        keywordFiles.push(saved);
        counts.reused = (counts.reused ?? 0) + 1;
        const rows = storedRowsByPath.get(e.path);
        if (rows) reusedRows.push(...rows);
      } else {
        toRead.push(e);
      }
    }

    // -- phase 1: read the changed files ----------------------------
    const newChunks: {
      id: string;
      path: string;
      name: string;
      folder: string;
      chunk: number;
      text: string;
    }[] = [];
    const readBase = keywordFiles.length;
    for (let i = 0; i < toRead.length; i++) {
      const entry = toRead[i];
      const name = path.basename(entry.path);
      const folder = path.dirname(entry.path);
      const ext = path.extname(entry.path).toLowerCase();
      this.progress('read', readBase + i + 1, total, `Reading ${name}`);
      // Let the window answer while a long build runs — without
      // this the per-file loop is one unbroken stretch of work and
      // Windows flags the window "(Not Responding)".
      await this.yieldSometimes();
      let content;
      try {
        content = await withTimeout(
          readFileContent(entry.path),
          READ_TIMEOUT_MS,
        );
      } catch {
        counts.errors += 1;
        if ((counts.skippedNames?.length ?? 0) < SKIPPED_NAMES_MAX) {
          counts.skippedNames?.push(name);
        }
        console.log(`DJ: skipped ${name} (too slow to read)`);
        continue;
      }
      if (content.status === 'unreadable') {
        counts.errors += 1;
        if ((counts.skippedNames?.length ?? 0) < SKIPPED_NAMES_MAX) {
          counts.skippedNames?.push(name);
        }
        console.log(`DJ: skipped ${name} (could not be read)`);
        continue;
      }
      if (content.status === 'no-text' || content.status === 'encrypted') {
        // Indexed by name, with an honest note — a scanned PDF is
        // still findable, and the result says why it has no text.
        counts.files += 1;
        counts.new = (counts.new ?? 0) + 1;
        keywordFiles.push({
          path: entry.path,
          name,
          folder,
          text: '',
          size: entry.size,
          mtimeMs: entry.mtimeMs,
          note: noTextNote(entry.path, content.status),
        });
        continue;
      }
      const text = content.text;
      if (!text.trim()) {
        counts.skipped += 1;
        continue;
      }
      counts.files += 1;
      counts.new = (counts.new ?? 0) + 1;
      keywordFiles.push({
        path: entry.path,
        name,
        folder,
        text: text.slice(0, KEYWORD_TEXT_LIMIT),
        size: entry.size,
        mtimeMs: entry.mtimeMs,
      });
      // PDFs chunk page by page; everything else chunks by words.
      const chunks = ext === '.pdf' ? chunkPdfText(text) : chunkText(text);
      const fid = fileId(entry.path);
      for (let j = 0; j < chunks.length; j++) {
        newChunks.push({
          id: `${fid}-${j}`,
          path: entry.path,
          name,
          folder,
          chunk: j,
          text: chunks[j],
        });
      }
    }

    // Save the keyword index NOW, before embedding: keyword search
    // works from this moment, even if the model takes minutes.
    const foldersFound = await this.iterFolders(folders);
    counts.folders = foldersFound.length;
    this.keywordFiles = keywordFiles;
    this.keywordFolders = foldersFound;
    this.keywordRepo.save({ version: 1, files: keywordFiles, folders: foldersFound });
    counts.files = keywordFiles.length;
    this.progress(
      'read',
      total,
      total,
      `Keyword search ready: ${keywordFiles.length} files. Embedding ${newChunks.length} new chunks...`,
    );

    // -- phase 2: embed only the new chunks, in small batches ------
    const newRows: StoredVector[] = [];
    let batchTexts: string[] = [];
    let batchMetas: {
      id: string;
      path: string;
      name: string;
      folder: string;
      chunk: number;
      text: string;
    }[] = [];

    const flushBatch = async (): Promise<void> => {
      if (batchTexts.length === 0) return;
      const texts = batchTexts;
      const metas = batchMetas;
      batchTexts = [];
      batchMetas = [];
      const vecs = await this.embedder.embedTexts(texts, false);
      if (vecs && vecs.length === texts.length) {
        texts.forEach((text, i) => {
          newRows.push({ ...metas[i], text, vector: Float32Array.from(vecs[i]) });
        });
      } else {
        counts.keywordOnly += texts.length;
      }
      // Yield after every batch: the model runs in the renderer,
      // and small batches keep the window answering between them.
      await this.yieldSometimes();
    };

    for (let i = 0; i < newChunks.length; i++) {
      batchTexts.push(newChunks[i].text);
      batchMetas.push(newChunks[i]);
      if (batchTexts.length >= EMBED_BATCH) {
        await flushBatch();
        this.progress(
          'read',
          readBase + toRead.length,
          total,
          `Embedding new chunks... ${newRows.length + reusedRows.length} with meaning search`,
        );
      }
    }
    await flushBatch();

    // Save vectors: reused rows plus the new ones. When the
    // embedder was down, reused rows are still kept — the build
    // never wipes good vectors because the model was off.
    counts.chunks = reusedRows.length + newChunks.length;
    counts.embedded = reusedRows.length + newRows.length;
    const allRows = [...reusedRows, ...newRows];
    if (allRows.length > 0) {
      this.store.replace(allRows, 'Xenova/nomic-embed-text-v1.5');
      this.vectorOk = true;
    } else {
      this.store.clear();
      this.vectorOk = false;
    }

    counts.seconds = Math.round((Date.now() - t0) / 100) / 10;
    counts.vectorOk = this.vectorOk;
    const mode = this.vectorOk ? 'ready' : 'not available, keyword search only';
    console.log(
      `DJ: index built: ${counts.files} files (${counts.new} new, ${counts.reused} reused, ${counts.removed} removed), ` +
        `${counts.folders} folders, ${counts.chunks} chunks in ${counts.seconds}s (meaning search ${mode})`,
    );
    this.progress(
      'done',
      total,
      total,
      `Done: ${counts.files} files (${counts.new} new, ${counts.reused} reused, ${counts.removed} removed), ${counts.chunks} chunks in ${counts.seconds}s.`,
    );
    return counts;
  }

  // -- search -------------------------------------------------------------

  /**
   * Search, keyword first. Keyword matching is instant, and a file
   * whose NAME matches the query is what the user typed — it wins
   * outright, without waiting on the model. That matters for files
   * with no readable text (a scanned PDF has no chunks and no
   * vectors, so only its name can ever find it): a weak meaning
   * match must not hide it. Otherwise, when the model is ready,
   * meaning search runs and its hits merge with the keyword hits
   * (meaning first, keyword extras after, no duplicates). When the
   * model is NOT ready, the search does not wait for it at all —
   * keyword results answer at once, with a plain note saying
   * meaning search is still loading or unavailable. A search never
   * waits the 5-minute build timeout, nor the 8-second query one,
   * when the model is not ready.
   */
  async search(query: string, topN = 8): Promise<SearchResult[]> {
    const q = (query || '').trim();
    if (!q) return [];
    const kw = this.keywordSearch(q, topN);
    if (this.nameMatches(q, kw)) {
      this.lastMeaning = 'ready';
      return kw;
    }
    if (this.vectorOk && this.embedder.isReady()) {
      const vec = await this.vectorSearch(q, topN);
      if (vec.length > 0) {
        this.lastMeaning = 'ready';
        return this.mergeResults(vec, kw, topN);
      }
      // Meaning ran and found nothing: keyword answers, no note.
      this.lastMeaning = 'ready';
      return kw;
    }
    // Model not ready: keyword answers at once, and says so.
    this.lastMeaning = !this.vectorOk
      ? 'not-indexed'
      : this.embedder.state === 'unavailable'
        ? 'unavailable'
        : 'loading';
    const note =
      this.lastMeaning === 'loading' ? MEANING_LOADING_NOTE : MEANING_UNAVAILABLE_NOTE;
    return this.withMeaningNote(kw, note);
  }

  /** True when any keyword result matched by file NAME (not just
   *  by text inside the file). Same term split as keywordSearch. */
  private nameMatches(query: string, results: SearchResult[]): boolean {
    const terms = query
      .toLowerCase()
      .split(/\W+/)
      .filter((w) => w.length > 2);
    const words = terms.length > 0 ? terms : [query.toLowerCase()];
    return results.some((r) =>
      words.some((w) => r.name.toLowerCase().includes(w)),
    );
  }

  /** Meaning hits first, then keyword-only extras, no duplicates. */
  private mergeResults(vec: SearchResult[], kw: SearchResult[], topN: number): SearchResult[] {
    const seen = new Set(vec.map((r) => r.path));
    const out = [...vec];
    for (const r of kw) {
      if (out.length >= topN) break;
      if (seen.has(r.path)) continue;
      seen.add(r.path);
      out.push(r);
    }
    return out;
  }

  /** Attach a plain note to keyword results (a file's own note,
   *  e.g. a scanned PDF, is kept and the meaning note is added
   *  after it). Same wording as chatService.meaningNote. */
  private withMeaningNote(results: SearchResult[], note: string): SearchResult[] {
    return results.map((r) => ({
      ...r,
      note: r.note ? `${r.note} ${note}` : note,
    }));
  }

  private async vectorSearch(query: string, topN: number): Promise<SearchResult[]> {
    const vec = await this.embedder.embedQuery(query);
    if (!vec) return [];
    const hits = this.store.search(vec, topN * 2);
    const seen = new Map<string, SearchResult>();
    for (const hit of hits) {
      if (seen.has(hit.path)) continue;
      seen.set(hit.path, {
        path: hit.path,
        name: hit.name,
        folder: hit.folder,
        snippet: hit.text.replace(/\s+/g, ' ').trim().slice(0, 160),
        score: hit.score,
        ...statMeta(hit.path),
      });
      if (seen.size >= topN) break;
    }
    return [...seen.values()];
  }

  /** Plain word search over file names and file text. A word in the
   * file name scores 10, a word in the text scores 1 per hit
   * (capped at 20). Best matches first. */
  keywordSearch(query: string, topN = 8): SearchResult[] {
    const words = query
      .toLowerCase()
      .split(/\W+/)
      .filter((w) => w.length > 2);
    const terms = words.length > 0 ? words : [query.toLowerCase()];
    const scored: { score: number; entry: IndexedFile }[] = [];
    for (const entry of this.keywordFiles) {
      const name = entry.name.toLowerCase();
      const low = entry.text.toLowerCase();
      let score = 0;
      for (const w of terms) {
        if (name.includes(w)) score += 10;
        score += Math.min(countOccurrences(low, w), 20);
      }
      if (score > 0) scored.push({ score, entry });
    }
    scored.sort((a, b) => b.score - a.score);
    return scored.slice(0, topN).map(({ score, entry }) => ({
      path: entry.path,
      name: entry.name,
      folder: entry.folder,
      // A file with no readable text (scanned PDF) still shows
      // its honest note instead of an empty snippet.
      snippet: entry.text ? snippet(entry.text, query) : (entry.note ?? ''),
      score,
      note: entry.note,
      ...statMeta(entry.path),
    }));
  }

  /** Read a file's text (for summaries). */
  getFileText(filePath: string, maxChars = 8000): Promise<string> {
    return readText(filePath).then((t) => t.slice(0, maxChars));
  }

  /** All indexed files, newest first (for "list recent files"). */
  listRecent(topN = 10): { path: string; name: string; folder: string; mtime: number; size?: number }[] {
    const rows: { path: string; name: string; folder: string; mtime: number; size?: number }[] = [];
    for (const entry of this.keywordFiles) {
      let mtime = 0;
      let size: number | undefined;
      try {
        const st = fs.statSync(entry.path);
        mtime = st.mtimeMs;
        size = st.size;
      } catch {
        continue;
      }
      rows.push({ path: entry.path, name: entry.name, folder: entry.folder, mtime, size });
    }
    rows.sort((a, b) => b.mtime - a.mtime);
    return rows.slice(0, topN);
  }
}

/** Words that carry no meaning in a folder query ("open the frontend folder"). */
const FOLDER_STOPWORDS = new Set([
  'folder', 'folders', 'directory', 'directories', 'the', 'a', 'an', 'in',
  'open', 'find', 'show', 'go', 'to', 'that', 'this', 'related', 'please',
]);

/**
 * Rank folders for a query, best first (at most 8). Pure function —
 * easy to test. Scoring: an exact name match wins; a query whose
 * words all appear across the name and the parent path (e.g.
 * "AuPro frontend" for the frontend folder inside AuPro) is nearly
 * as strong; a partial name match is weaker; a word in the parent
 * path (the project) breaks ties between same-named folders in
 * different projects. Only folders close to the best score are
 * returned — a clear winner does not drag weaker matches along.
 */
export function rankFolders(folders: IndexedFolder[], query: string): IndexedFolder[] {
  const words = (query || '')
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter((w) => w.length > 0 && !FOLDER_STOPWORDS.has(w));
  if (words.length === 0) return [];
  const phrase = words.join(' ');
  const scored: { score: number; folder: IndexedFolder }[] = [];
  for (const folder of folders) {
    const name = folder.name.toLowerCase();
    const parent = folder.parent.toLowerCase();
    const fullPath = folder.path.toLowerCase();
    let score = 0;
    if (name === phrase) {
      score += 100;
    } else if (words.every((w) => name.includes(w) || parent.includes(w))) {
      // Every word appears somewhere in name + parent: the folder is
      // the one the user described ("AuPro frontend").
      score += 70;
    } else {
      for (const w of words) {
        if (name.includes(w)) score += 25;
      }
      let parentHits = 0;
      for (const w of words) {
        if (parent.includes(w)) parentHits += 1;
      }
      score += Math.min(parentHits * 10, 20);
    }
    if (fullPath.includes(phrase)) score += 15;
    if (score > 0) scored.push({ score, folder });
  }
  scored.sort(
    (a, b) =>
      b.score - a.score ||
      a.folder.path.length - b.folder.path.length ||
      a.folder.name.localeCompare(b.folder.name),
  );
  if (scored.length === 0) return [];
  const best = scored[0].score;
  return scored
    .filter((s) => s.score >= best - 20)
    .slice(0, 8)
    .map((s) => s.folder);
}

function isDirectory(p: string): boolean {
  try {
    return fs.statSync(p).isDirectory();
  } catch {
    return false;
  }
}
