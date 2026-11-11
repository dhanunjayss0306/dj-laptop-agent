// DJ v3 — vector store. Brute-force cosine search over the stored
// vectors, in memory. At this scale (tens of thousands of chunks)
// brute force is a few milliseconds per query and needs no server,
// no native module, and no database process — the simplest reliable
// choice. Vectors are L2-normalized when stored, so cosine
// similarity is a plain dot product.

import type { StoredVector } from '../domain/types';
import { VectorRepository } from '../repositories/vectorRepository';

export interface VectorHit {
  id: string;
  path: string;
  name: string;
  folder: string;
  chunk: number;
  text: string;
  score: number;
}

function normalize(v: Float32Array): Float32Array {
  let sum = 0;
  for (let i = 0; i < v.length; i++) sum += v[i] * v[i];
  const len = Math.sqrt(sum) || 1;
  const out = new Float32Array(v.length);
  for (let i = 0; i < v.length; i++) out[i] = v[i] / len;
  return out;
}

export class VectorStore {
  private rows: StoredVector[] = [];
  private readonly repo: VectorRepository;

  constructor(dataDir: string) {
    this.repo = new VectorRepository(dataDir);
  }

  /** Load whatever is on disk. True when vectors were found. */
  loadFromDisk(): boolean {
    const loaded = this.repo.load();
    if (!loaded) {
      this.rows = [];
      return false;
    }
    this.rows = loaded.metas.map((m, i) => ({
      ...m,
      vector: loaded.vectors[i],
    }));
    return this.rows.length > 0;
  }

  get size(): number {
    return this.rows.length;
  }

  /** Replace the store with new rows (normalized) and persist them. */
  replace(rows: StoredVector[], embedModel: string): void {
    this.rows = rows.map((r) => ({ ...r, vector: normalize(r.vector) }));
    this.repo.save(
      this.rows.map(({ id, path, name, folder, chunk, text }) => ({
        id,
        path,
        name,
        folder,
        chunk,
        text,
      })),
      this.rows.map((r) => r.vector),
      embedModel,
    );
  }

  clear(): void {
    this.rows = [];
    this.repo.clear();
  }

  storedFormat(): number | null {
    return this.repo.storedFormat();
  }

  hasStoredVectors(): boolean {
    return this.repo.exists();
  }

  /** Top matches for a query vector, best first. */
  search(queryVector: number[] | Float32Array, topN: number): VectorHit[] {
    if (this.rows.length === 0) return [];
    const raw =
      queryVector instanceof Float32Array
        ? queryVector
        : Float32Array.from(queryVector);
    // A zero query has no direction — nothing matches it.
    let qSum = 0;
    for (let i = 0; i < raw.length; i++) qSum += raw[i] * raw[i];
    if (qSum === 0) return [];
    const q = normalize(raw);
    const scored: { row: StoredVector; score: number }[] = [];
    for (const row of this.rows) {
      const v = row.vector;
      // Dot over the shorter length: stored rows are 768-dim, but a
      // shorter query (tests, or a future model) must not read past
      // the end of the array and produce NaN.
      const dim = Math.min(q.length, v.length);
      let dot = 0;
      for (let i = 0; i < dim; i++) dot += q[i] * v[i];
      scored.push({ row, score: dot });
    }
    scored.sort((a, b) => b.score - a.score);
    return scored.slice(0, topN).map(({ row, score }) => ({
      id: row.id,
      path: row.path,
      name: row.name,
      folder: row.folder,
      chunk: row.chunk,
      text: row.text,
      score: Math.round(score * 1000) / 1000,
    }));
  }
}
