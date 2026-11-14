// DJ v3 — domain types (main process only).

export interface IndexedFile {
  path: string;
  name: string;
  folder: string;
  /** First 12,000 chars of the file text, for keyword search. */
  text: string;
  /** File size in bytes at index time — for incremental rebuilds. */
  size?: number;
  /** Last-modified time (ms since epoch) at index time. */
  mtimeMs?: number;
  /** Plain-language note when the file has no readable text
   *  (scanned PDF, locked PDF) — shown instead of a snippet. */
  note?: string;
}

/** A folder DJ knows about (recorded at index time, by name). */
export interface IndexedFolder {
  path: string;
  name: string;
  /** The folder this folder lives in. */
  parent: string;
}

export interface ChunkRecord {
  id: string;
  path: string;
  name: string;
  folder: string;
  chunk: number;
  text: string;
}

export interface StoredVector {
  id: string;
  path: string;
  name: string;
  folder: string;
  chunk: number;
  text: string;
  vector: Float32Array;
}
