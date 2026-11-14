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

import type { EmbedRequest, EmbedResponse, EmbedderSource } from '../../shared/types';
import { EMBED_MODEL_ID } from '../../shared/modelSource';

export { EMBED_MODEL_ID };
export const EMBED_DIM = 768;

export const DOC_PREFIX = 'search_document: ';
export const QUERY_PREFIX = 'search_query: ';

// How long the renderer may take to load the tiny model and embed
// the first text before an index build gives up on meaning search
// and falls back to keyword search. 5 minutes: the first load
// compiles a 137 MB model in WASM, which is slow on a weak machine
// (the v3.3 smoke test watched a 120 s cap expire on this VM),
// and it only happens once per app start — after that the model
// stays loaded in memory.
const EMBED_TIMEOUT_MS = 300_000;

// How long a SEARCH waits for the model. A search must never sit
// on the 5-minute build timeout: if the model is not ready within
// 8 seconds, the search answers with keyword results at once and
// says plainly that meaning search is still loading. The model
// keeps loading in the background for the next search.
const QUERY_TIMEOUT_MS = 8_000;

export type EmbedderState = 'ready' | 'loading' | 'unavailable' | 'not-started';

export class EmbedderClient {
  /** 'not-started' until the first embed is attempted. */
  state: EmbedderState = 'not-started';
  /** Where the running model came from — 'none' until one loads. */
  source: EmbedderSource = 'none';

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

  /** Called by the IPC layer when the renderer reports its model source. */
  onRendererSource(source: string): void {
    if (source === 'bundled' || source === 'downloaded' || source === 'none') {
      this.source = source;
    }
  }

  /** True when the model has loaded and can embed right now. */
  isReady(): boolean {
    return this.state === 'ready';
  }

  /** Embed texts. Returns vectors, or null when unavailable.
   *  timeoutMs caps how long this one call may wait (build flushes
   *  allow the long first-load window; searches use the short one). */
  embedTexts(
    texts: string[],
    forQuery = false,
    timeoutMs: number = EMBED_TIMEOUT_MS,
  ): Promise<number[][] | null> {
    if (texts.length === 0) return Promise.resolve([]);
    const prefix = forQuery ? QUERY_PREFIX : DOC_PREFIX;
    const sendTexts = texts.map((t) => prefix + t);
    const id = `embed-${this.nextId++}`;
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        // A timed-out search must not poison the embedder: the
        // model may still be loading. Only a build flush that
        // waited the full window marks it unavailable.
        if (!forQuery) this.state = 'unavailable';
        resolve(null);
      }, timeoutMs);
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

  /** Embed one search query. Returns one vector, or null — fast:
   *  at most QUERY_TIMEOUT_MS, never the 5-minute build window. */
  async embedQuery(query: string): Promise<number[] | null> {
    const vecs = await this.embedTexts([query], true, QUERY_TIMEOUT_MS);
    return vecs && vecs.length > 0 ? vecs[0] : null;
  }
}
