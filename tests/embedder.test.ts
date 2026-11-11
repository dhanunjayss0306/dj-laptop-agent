// DJ v3 tests — embedder client (main side). The real model runs
// in the renderer, so these tests stub the IPC send and answer like
// the renderer would. They check the prefixes the nomic model needs
// and the fallback behaviour.

import { describe, expect, it, vi } from 'vitest';

import {
  DOC_PREFIX,
  EmbedderClient,
  QUERY_PREFIX,
} from '../src/main/services/embedderClient';
import type { EmbedRequest } from '../src/shared/types';

function makeClient(
  answer?: (req: EmbedRequest) => void,
): { client: EmbedderClient; sent: EmbedRequest[]; send: ReturnType<typeof vi.fn> } {
  const sent: EmbedRequest[] = [];
  const send = vi.fn((req: EmbedRequest): boolean => {
    sent.push(req);
    answer?.(req);
    return true;
  });
  const client = new EmbedderClient(send);
  return { client, sent, send };
}

describe('prefixes: the nomic model needs them', () => {
  it('documents get the search_document: prefix', async () => {
    const { client, sent } = makeClient((req) => {
      client.onResponse({ id: req.id, vectors: [[0.1, 0.2]] });
    });
    const vecs = await client.embedTexts(['hello world'], false);
    expect(vecs).toEqual([[0.1, 0.2]]);
    expect(sent[0].texts[0]).toBe(`${DOC_PREFIX}hello world`);
  });
  it('queries get the search_query: prefix', async () => {
    const { client, sent } = makeClient((req) => {
      client.onResponse({ id: req.id, vectors: [[0.3, 0.4]] });
    });
    const vec = await client.embedQuery('travel and tourism');
    expect(vec).toEqual([0.3, 0.4]);
    expect(sent[0].texts[0]).toBe(`${QUERY_PREFIX}travel and tourism`);
  });
  it('the prefixes are exactly what nomic-embed-text-v1.5 was trained with', () => {
    expect(DOC_PREFIX).toBe('search_document: ');
    expect(QUERY_PREFIX).toBe('search_query: ');
  });
});

describe('fallback: when the renderer cannot embed', () => {
  it('returns null when there is no window to send to', async () => {
    const client = new EmbedderClient(() => false);
    const vecs = await client.embedTexts(['hello'], false);
    expect(vecs).toBeNull();
    expect(client.state).toBe('unavailable');
  });
  it('returns null when the renderer reports an error', async () => {
    const { client } = makeClient((req) => {
      client.onResponse({ id: req.id, vectors: null, error: 'model failed to load' });
    });
    const vecs = await client.embedTexts(['hello'], false);
    expect(vecs).toBeNull();
    expect(client.state).toBe('unavailable');
  });
  it('an empty list embeds to an empty list (no IPC call)', async () => {
    const { client, send } = makeClient();
    const vecs = await client.embedTexts([], false);
    expect(vecs).toEqual([]);
    expect(send).not.toHaveBeenCalled();
  });
});

describe('state', () => {
  it('starts as not-started, becomes ready on a good answer', async () => {
    const { client } = makeClient((req) => {
      client.onResponse({ id: req.id, vectors: [[1]] });
    });
    expect(client.state).toBe('not-started');
    await client.embedTexts(['hello'], false);
    expect(client.state).toBe('ready');
  });
  it('two requests in flight resolve independently', async () => {
    const { client, sent } = makeClient();
    const p1 = client.embedTexts(['one'], false);
    const p2 = client.embedTexts(['two'], false);
    client.onResponse({ id: sent[1].id, vectors: [[2]] });
    client.onResponse({ id: sent[0].id, vectors: [[1]] });
    expect(await p1).toEqual([[1]]);
    expect(await p2).toEqual([[2]]);
  });
});
