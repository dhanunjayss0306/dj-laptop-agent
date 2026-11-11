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
import type { IndexedFile, IndexedFolder } from '../domain/types';
import { KeywordIndexRepository } from '../repositories/keywordIndexRepository';
import { EMBED_FORMAT_VERSION } from '../repositories/vectorRepository';
import { fileId } from '../utils/hashing';
import { chunkText, countOccurrences, snippet } from '../utils/text';
import type { EmbedderClient } from './embedderClient';
import { readText } from './fileReader';
import { VectorStore } from './vectorStore';

// File types DJ can read text from.
export const READABLE_EXTS = new Set([
  '.txt', '.md', '.py', '.js', '.ts', '.jsx', '.tsx', '.html', '.css',
  '.json', '.csv', '.log', '.pdf', '.docx',
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

const EMBED_BATCH = 10;

export type ProgressCallback = (p: IndexProgress) => void;

export class IndexService {
  private readonly keywordRepo: KeywordIndexRepository;
  private readonly store: VectorStore;
  private keywordFiles: IndexedFile[] = [];
  private keywordFolders: IndexedFolder[] = [];

  /** True when the vector store has usable vectors. */
  vectorOk = false;

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
    try {
      this.onProgress?.({ stage, done, total, message });
    } catch {
      // Progress display must never break the build.
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
   */
  iterFiles(folders: string[]): string[] {
    const found: string[] = [];
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
        this.walkDir(folder, (filePath) => {
          found.push(filePath);
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

  private walkDir(
    dir: string,
    onFile: (filePath: string) => void,
    seen: Set<string>,
    onDir?: (dirPath: string) => void,
  ): void {
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch (err) {
      console.log(`DJ: could not read a folder: ${err} (skipped)`);
      return;
    }
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        // Prune junk folders here: never descend into them.
        if (SKIP_DIRS.has(entry.name.toLowerCase())) continue;
        if (entry.name.startsWith('.')) continue;
        if (entry.isSymbolicLink()) continue;
        onDir?.(full);
        this.walkDir(full, onFile, seen, onDir);
      } else if (entry.isFile()) {
        if (entry.name.startsWith('.')) continue;
        if (!READABLE_EXTS.has(path.extname(entry.name).toLowerCase())) continue;
        let size = 0;
        try {
          size = fs.statSync(full).size;
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
        onFile(full);
      }
      // Anything else (sockets, fifos, ...): skip.
    }
  }

  // -- build ------------------------------------------------------------

  /**
   * Every directory under the given folders, by name — so DJ can open
   * a folder ("open the frontend folder"). Same skip rules as files:
   * junk and hidden folders are never recorded. The roots themselves
   * count too (so "open AuPro" works when AuPro is an indexed folder).
   */
  iterFolders(folders: string[]): IndexedFolder[] {
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
        this.walkDir(
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

  /** Build (or rebuild) the whole index. Returns counts. */
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
    };
    const t0 = Date.now();
    this.progress('scan', 0, 1, 'Looking through your folders...');
    const files = this.iterFiles(folders);
    const total = Math.max(files.length, 1);

    // Fresh vector store for this build; the old one is replaced
    // only if the new build produces vectors.
    const newRows: {
      id: string;
      path: string;
      name: string;
      folder: string;
      chunk: number;
      text: string;
      vector: Float32Array;
    }[] = [];
    let vectorOk = false;

    const keywordFiles: IndexedFile[] = [];
    let batchTexts: string[] = [];
    let batchMetas: { id: string; path: string; name: string; folder: string; chunk: number; text: string }[] = [];

    const flushBatch = async (): Promise<void> => {
      if (batchTexts.length === 0) return;
      const texts = batchTexts;
      const metas = batchMetas;
      batchTexts = [];
      batchMetas = [];
      const vecs = await this.embedder.embedTexts(texts, false);
      if (vecs && vecs.length === texts.length) {
        vectorOk = true;
        texts.forEach((text, i) => {
          counts.embedded += 1;
          newRows.push({ ...metas[i], text, vector: Float32Array.from(vecs[i]) });
        });
      } else {
        counts.keywordOnly += texts.length;
      }
    };

    for (let i = 0; i < files.length; i++) {
      const filePath = files[i];
      const name = path.basename(filePath);
      this.progress('read', i + 1, total, `Reading ${name}`);
      let text = '';
      try {
        text = await readText(filePath);
      } catch {
        counts.errors += 1;
        continue;
      }
      if (!text.trim()) {
        counts.skipped += 1;
        continue;
      }
      counts.files += 1;
      keywordFiles.push({
        path: filePath,
        name,
        folder: path.dirname(filePath),
        text: text.slice(0, KEYWORD_TEXT_LIMIT),
      });
      const chunks = chunkText(text);
      counts.chunks += chunks.length;
      const fid = fileId(filePath);
      for (let j = 0; j < chunks.length; j++) {
        batchTexts.push(chunks[j]);
        batchMetas.push({
          id: `${fid}-${j}`,
          path: filePath,
          name,
          folder: path.dirname(filePath),
          chunk: j,
          text: chunks[j],
        });
        // Flush in sequence when the batch is full: keeps memory
        // low and the progress bar honest.
        if (batchTexts.length >= EMBED_BATCH) {
          await flushBatch();
        }
      }
    }
    await flushBatch();

    // Save the keyword index, with the folder list beside it.
    const foldersFound = this.iterFolders(folders);
    counts.folders = foldersFound.length;
    this.keywordFiles = keywordFiles;
    this.keywordFolders = foldersFound;
    this.keywordRepo.save({ version: 1, files: keywordFiles, folders: foldersFound });

    // Save vectors only when the build produced them.
    if (vectorOk && newRows.length > 0) {
      this.store.replace(newRows, 'Xenova/nomic-embed-text-v1.5');
      this.vectorOk = true;
    } else {
      this.store.clear();
      this.vectorOk = false;
    }

    counts.seconds = Math.round((Date.now() - t0) / 100) / 10;
    counts.vectorOk = this.vectorOk;
    const mode = this.vectorOk ? 'ready' : 'not available, keyword search only';
    console.log(
      `DJ: index built: ${counts.files} files, ${counts.folders} folders, ${counts.chunks} chunks in ${counts.seconds}s (meaning search ${mode})`,
    );
    this.progress(
      'done',
      total,
      total,
      `Done: ${counts.files} files, ${counts.chunks} chunks in ${counts.seconds}s.`,
    );
    return counts;
  }

  // -- search -------------------------------------------------------------

  /** Search by meaning first, by keyword if vectors are not ready. */
  async search(query: string, topN = 8): Promise<SearchResult[]> {
    const q = (query || '').trim();
    if (!q) return [];
    if (this.vectorOk) {
      const results = await this.vectorSearch(q, topN);
      if (results.length > 0) return results;
    }
    return this.keywordSearch(q, topN);
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
      snippet: snippet(entry.text, query),
      score,
    }));
  }

  /** Read a file's text (for summaries). */
  getFileText(filePath: string, maxChars = 8000): Promise<string> {
    return readText(filePath).then((t) => t.slice(0, maxChars));
  }

  /** All indexed files, newest first (for "list recent files"). */
  listRecent(topN = 10): { path: string; name: string; folder: string; mtime: number }[] {
    const rows: { path: string; name: string; folder: string; mtime: number }[] = [];
    for (const entry of this.keywordFiles) {
      let mtime = 0;
      try {
        mtime = fs.statSync(entry.path).mtimeMs;
      } catch {
        continue;
      }
      rows.push({ path: entry.path, name: entry.name, folder: entry.folder, mtime });
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
