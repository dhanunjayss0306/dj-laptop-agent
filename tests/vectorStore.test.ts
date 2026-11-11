// DJ v3 tests — vector store: cosine search, normalize, persist.

import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { describe, expect, it } from 'vitest';

import { VectorStore } from '../src/main/services/vectorStore';

function row(id: string, vector: number[], text = id): {
  id: string;
  path: string;
  name: string;
  folder: string;
  chunk: number;
  text: string;
  vector: Float32Array;
} {
  return {
    id,
    path: `/fake/${id}.txt`,
    name: `${id}.txt`,
    folder: '/fake',
    chunk: 0,
    text,
    vector: Float32Array.from(vector),
  };
}

describe('search: cosine similarity', () => {
  it('finds the closest vector first', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-vec-'));
    const store = new VectorStore(dir);
    store.replace(
      [row('a', [1, 0, 0]), row('b', [0, 1, 0]), row('c', [0.9, 0.1, 0])],
      'test-model',
    );
    const hits = store.search([1, 0, 0], 3);
    expect(hits[0].id).toBe('a');
    expect(hits[0].score).toBeCloseTo(1, 5);
    expect(hits[1].id).toBe('c');
    expect(hits[2].id).toBe('b');
  });
  it('normalizes vectors on store (magnitude does not matter)', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-vec-'));
    const store = new VectorStore(dir);
    store.replace([row('a', [10, 0, 0])], 'test-model');
    const hits = store.search([1, 0, 0], 1);
    expect(hits[0].score).toBeCloseTo(1, 5);
  });
  it('a zero query returns nothing', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-vec-'));
    const store = new VectorStore(dir);
    store.replace([row('a', [1, 0, 0])], 'test-model');
    expect(store.search([0, 0, 0], 1)).toEqual([]);
  });
  it('empty store returns nothing', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-vec-'));
    const store = new VectorStore(dir);
    expect(store.search([1, 0, 0], 1)).toEqual([]);
  });
});

describe('persist: save and reload from disk', () => {
  it('a fresh store loads the saved vectors', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-vec-'));
    const store = new VectorStore(dir);
    store.replace([row('a', [1, 0, 0], 'hello world')], 'test-model');
    expect(store.hasStoredVectors()).toBe(true);

    const reloaded = new VectorStore(dir);
    expect(reloaded.loadFromDisk()).toBe(true);
    const hits = reloaded.search([1, 0, 0], 1);
    expect(hits.length).toBe(1);
    expect(hits[0].text).toBe('hello world');
  });
  it('clear removes the vectors', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-vec-'));
    const store = new VectorStore(dir);
    store.replace([row('a', [1, 0, 0])], 'test-model');
    store.clear();
    expect(store.hasStoredVectors()).toBe(false);
    expect(store.search([1, 0, 0], 1)).toEqual([]);
  });
  it('records the embedding format version', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-vec-'));
    const store = new VectorStore(dir);
    store.replace([row('a', [1, 0, 0])], 'test-model');
    expect(store.storedFormat()).toBe(2);
  });
});
