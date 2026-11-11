// DJ v3 — domain types (main process only).

export interface IndexedFile {
  path: string;
  name: string;
  folder: string;
  /** First 12,000 chars of the file text, for keyword search. */
  text: string;
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
