// DJ v3 — vector repository. Vectors are stored as one binary file
// of float32 numbers (vectors.bin) plus a small JSON file with the
// metadata for each vector (vectors_meta.json). No server, no
// database process — just files on this laptop.
//
// Layout of vectors.bin: rows of DIM float32 values, one row per
// vector, in the same order as the meta array. DIM is fixed at 768
// (nomic-embed-text-v1.5).

import * as fs from 'fs';
import * as path from 'path';

import { CHUNK_VERSION } from '../utils/text';

export const VECTOR_DIM = 768;
export const EMBED_FORMAT_VERSION = 2;
// Format 1: raw text, no prefixes. Format 2: nomic task prefixes.

export interface VectorMeta {
  id: string;
  path: string;
  name: string;
  folder: string;
  chunk: number;
  text: string;
}

export interface VectorMetaFile {
  embedFormat: number;
  embedModel: string;
  dim: number;
  /** Chunking scheme the stored rows were built with (v5.5+;
   *  missing in older stores, which count as version 0). */
  chunkVersion?: number;
  vectors: VectorMeta[];
}

const BIN_NAME = 'vectors.bin';
const META_NAME = 'vectors_meta.json';
const INDEX_META_NAME = 'index_meta.json';

export class VectorRepository {
  constructor(private readonly dataDir: string) {}

  private binPath(): string {
    return path.join(this.dataDir, BIN_NAME);
  }

  private metaPath(): string {
    return path.join(this.dataDir, META_NAME);
  }

  private indexMetaPath(): string {
    return path.join(this.dataDir, INDEX_META_NAME);
  }

  exists(): boolean {
    return fs.existsSync(this.binPath()) && fs.existsSync(this.metaPath());
  }

  /** Load all vectors. Returns null when nothing is stored. */
  load(): { metas: VectorMeta[]; vectors: Float32Array[]; chunkVersion: number } | null {
    try {
      if (!this.exists()) return null;
      const meta = JSON.parse(
        fs.readFileSync(this.metaPath(), 'utf-8'),
      ) as VectorMetaFile;
      if (meta.dim !== VECTOR_DIM || !Array.isArray(meta.vectors)) return null;
      const buf = fs.readFileSync(this.binPath());
      const floats = new Float32Array(
        buf.buffer,
        buf.byteOffset,
        buf.byteLength / 4,
      );
      if (floats.length !== meta.vectors.length * VECTOR_DIM) return null;
      const vectors: Float32Array[] = [];
      for (let i = 0; i < meta.vectors.length; i++) {
        vectors.push(floats.slice(i * VECTOR_DIM, (i + 1) * VECTOR_DIM));
      }
      // Older stores have no chunkVersion — they count as 0.
      const chunkVersion =
        typeof meta.chunkVersion === 'number' ? meta.chunkVersion : 0;
      return { metas: meta.vectors, vectors, chunkVersion };
    } catch {
      return null;
    }
  }

  /** Replace everything stored with the given rows. */
  save(metas: VectorMeta[], vectors: Float32Array[], embedModel: string): void {
    fs.mkdirSync(this.dataDir, { recursive: true });
    const flat = new Float32Array(metas.length * VECTOR_DIM);
    vectors.forEach((v, i) => flat.set(v, i * VECTOR_DIM));
    fs.writeFileSync(this.binPath(), Buffer.from(flat.buffer));
    const meta: VectorMetaFile = {
      embedFormat: EMBED_FORMAT_VERSION,
      embedModel,
      dim: VECTOR_DIM,
      chunkVersion: CHUNK_VERSION,
      vectors: metas,
    };
    fs.writeFileSync(this.metaPath(), JSON.stringify(meta), 'utf-8');
    fs.writeFileSync(
      this.indexMetaPath(),
      JSON.stringify({
        embedFormat: EMBED_FORMAT_VERSION,
        embedModel,
        chunkVersion: CHUNK_VERSION,
      }),
      'utf-8',
    );
  }

  /** Remove all stored vectors (a rebuild starts clean). */
  clear(): void {
    for (const p of [this.binPath(), this.metaPath(), this.indexMetaPath()]) {
      try {
        fs.unlinkSync(p);
      } catch {
        // Already gone.
      }
    }
  }

  /** The embedding format the stored vectors were built with. */
  storedFormat(): number | null {
    try {
      const meta = JSON.parse(
        fs.readFileSync(this.indexMetaPath(), 'utf-8'),
      ) as { embedFormat?: number };
      return typeof meta.embedFormat === 'number' ? meta.embedFormat : null;
    } catch {
      return null;
    }
  }

  /** The chunking scheme the stored vectors were built with
   *  (0 when the store predates chunk versions). */
  storedChunkVersion(): number {
    try {
      const meta = JSON.parse(
        fs.readFileSync(this.indexMetaPath(), 'utf-8'),
      ) as { chunkVersion?: number };
      return typeof meta.chunkVersion === 'number' ? meta.chunkVersion : 0;
    } catch {
      return 0;
    }
  }
}
