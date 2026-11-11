// DJ v3 — embedder client (main-process side).
//
// The tiny embedding model itself runs in the RENDERER process
// (Chromium), where @huggingface/transformers uses the WebAssembly
// ONNX backend — no native module, no rebuild, no server, no
// LM Studio. This client only asks the renderer to embed texts and
// waits for the vectors back, over IPC.
//
// nomic-embed-text-v1.5 was trained with task prefixes — DJ sends
// "search_document: " in front of indexed chunks and "search_query: "
// in front of a search query. The prefixes are only sent to the
// model; the stored texts are unchanged. Without them retrieval gets
// worse, silently — no error is raised.

import type { EmbedRequest, EmbedResponse } from '../../shared/types';

export const EMBED_MODEL_ID = 'Xenova/nomic-embed-text-v1.5';
export const EMBED_DIM = 768;

export const DOC_PREFIX = 'search_document: ';
export const QUERY_PREFIX = 'search_query: ';

const EMBED_TIMEOUT_MS = 120_000;

export type EmbedderState = 'ready' | 'loading' | 'unavailable' | 'not-started';

export class EmbedderClient {
  /** 'not-started' until the first embed is attempted. */
  state: EmbedderState = 'not-started';

  private readonly sendRequest: (req: EmbedRequest) => boolean;
  private readonly pending = new Map<
    string,
    {
      resolve: (v: number[][] | null) => void;
      timer: NodeJS.Timeout;
    }
  >();
  private nextId = 1;

  /**
   * @param sendRequest sends an EmbedRequest to the renderer.
   *   Returns false when there is no window to send it to.
   */
  constructor(sendRequest: (req: EmbedRequest) => boolean) {
    this.sendRequest = sendRequest;
  }

  /** Called by the IPC layer when the renderer answers a request. */
  onResponse(resp: EmbedResponse): void {
    const entry = this.pending.get(resp.id);
    if (!entry) return;
    this.pending.delete(resp.id);
    clearTimeout(entry.timer);
    if (resp.error || !resp.vectors) {
      this.state = 'unavailable';
      entry.resolve(null);
      return;
    }
    this.state = 'ready';
    entry.resolve(resp.vectors);
  }

  /** Called by the IPC layer when the renderer reports its state. */
  onRendererState(state: string): void {
    if (state === 'loading') this.state = 'loading';
    else if (state === 'ready') this.state = 'ready';
    else if (state === 'unavailable') this.state = 'unavailable';
  }

  /** Embed texts. Returns vectors, or null when unavailable. */
  embedTexts(texts: string[], forQuery = false): Promise<number[][] | null> {
    if (texts.length === 0) return Promise.resolve([]);
    const prefix = forQuery ? QUERY_PREFIX : DOC_PREFIX;
    const sendTexts = texts.map((t) => prefix + t);
    const id = `embed-${this.nextId++}`;
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        this.state = 'unavailable';
        resolve(null);
      }, EMBED_TIMEOUT_MS);
      this.pending.set(id, { resolve, timer });
      if (this.state === 'not-started') this.state = 'loading';
      const sent = this.sendRequest({ id, texts: sendTexts, forQuery });
      if (!sent) {
        clearTimeout(timer);
        this.pending.delete(id);
        this.state = 'unavailable';
        resolve(null);
      }
    });
  }

  /** Embed one search query. Returns one vector, or null. */
  async embedQuery(query: string): Promise<number[] | null> {
    const vecs = await this.embedTexts([query], true);
    return vecs && vecs.length > 0 ? vecs[0] : null;
  }
}
