// DJ v3 — renderer embedder. The tiny embedding model itself runs
// HERE, inside the app window (Chromium), using the WebAssembly
// ONNX backend of @huggingface/transformers. No native module, no
// server, no LM Studio, nothing leaves the laptop.
//
// The model is nomic-embed-text-v1.5 (Xenova ONNX, ~150 MB). It
// downloads from the Hugging Face hub ONCE, the first time DJ needs
// meaning search, and the browser cache keeps it after that. The
// main process sends texts to embed over IPC; this module answers
// with the vectors. Main adds the search_document:/search_query:
// prefixes before sending, so this module never has to.
//
// If the download fails (no internet on first run, hub down), the
// module reports 'unavailable' and DJ falls back to keyword search
// — search still works, it just cannot find files by meaning.

import { pipeline, env } from '@huggingface/transformers';
import type { EmbedRequest, EmbedResponse } from '../shared/types';

// The model files come from the Hugging Face hub on first use.
env.allowLocalModels = false;

export const EMBED_MODEL_ID = 'Xenova/nomic-embed-text-v1.5';

export type EmbedderState = 'ready' | 'loading' | 'unavailable' | 'not-started';

// eslint-disable-next-line @typescript-eslint/no-explicit-any
let extractor: any = null;
let state: EmbedderState = 'not-started';
let loadPromise: Promise<void> | null = null;

export function getEmbedderState(): EmbedderState {
  return state;
}

/** Load the model (once). Reports progress through onProgress. */
export async function loadEmbedder(
  onProgress?: (p: { progress: number; status: string }) => void,
): Promise<boolean> {
  if (extractor) {
    state = 'ready';
    return true;
  }
  if (loadPromise) {
    await loadPromise;
    return extractor !== null;
  }
  state = 'loading';
  reportEmbedderState();
  loadPromise = (async () => {
    try {
      extractor = await pipeline('feature-extraction', EMBED_MODEL_ID, {
        dtype: 'q8',
        progress_callback: (p: { progress?: number; status?: string }) => {
          onProgress?.({
            progress: typeof p.progress === 'number' ? p.progress : 0,
            status: p.status ?? 'loading',
          });
        },
      });
      state = 'ready';
    } catch (err) {
      console.error('DJ: could not load the embedding model:', err);
      extractor = null;
      state = 'unavailable';
    } finally {
      loadPromise = null;
      reportEmbedderState();
    }
  })();
  await loadPromise;
  return extractor !== null;
}

/** Embed already-prefixed texts. Returns vectors, or null. */
export async function embedTexts(texts: string[]): Promise<number[][] | null> {
  const ok = await loadEmbedder();
  if (!ok || !extractor) return null;
  try {
    // Mean-pooled, L2-normalized: one 768-number vector per text.
    const output = await extractor(texts, { pooling: 'mean', normalize: true });
    const data: number[][] = output.tolist() as number[][];
    return Array.isArray(data[0]) ? data : [data as unknown as number[]];
  } catch (err) {
    console.error('DJ: embedding failed:', err);
    state = 'unavailable';
    reportEmbedderState();
    return null;
  }
}

/**
 * Handle one embed request from the main process, and answer it.
 * Wired up by the app's entry point (main.tsx) once, at startup.
 */
export function handleEmbedRequest(req: EmbedRequest): void {
  void (async () => {
    const vectors = await embedTexts(req.texts);
    const resp: EmbedResponse = vectors
      ? { id: req.id, vectors }
      : { id: req.id, vectors: null, error: 'Embedding is unavailable (model not loaded).' };
    window.dj.sendEmbedResponse(resp);
  })();
}

/** Tell main the renderer's embedder state (for the status bar). */
export function reportEmbedderState(): void {
  if (typeof window !== 'undefined' && window.dj) {
    window.dj.sendEmbedderState(state);
  }
}
