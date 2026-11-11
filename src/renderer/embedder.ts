// DJ v3.3 — renderer embedder. The tiny embedding model itself runs
// HERE, inside the app window (Chromium), using the WebAssembly
// ONNX backend of @huggingface/transformers. No native module, no
// server, no LM Studio, nothing leaves the laptop.
//
// The model is nomic-embed-text-v1.5 (official nomic-ai repo, ~150 MB).
// It ships INSIDE the installed app: the main process serves the
// bundled files on the private dj-model:// scheme, and transformers.js
// loads them through env.localModelPath. No download on first run.
// If the bundled copy is missing (or this is a dev run without it),
// transformers.js falls back to downloading the same repo from the
// Hugging Face hub once, and the browser cache keeps it after that.
// The main process sends texts to embed over IPC; this module answers
// with the vectors. Main adds the search_document:/search_query:
// prefixes before sending, so this module never has to.
//
// If the model cannot load at all (no bundled copy, no internet),
// the module reports 'unavailable' and DJ falls back to keyword
// search — search still works, it just cannot find files by meaning.

import { pipeline, env } from '@huggingface/transformers';
import type { EmbedRequest, EmbedResponse, EmbedderSource } from '../shared/types';
import { EMBED_MODEL_ID, MODEL_BASE_URL, modelUrlForFile } from '../shared/modelSource';

// Load from the bundled copy first (dj-model://, served by main),
// and only download from the Hugging Face hub when it is missing.
env.allowLocalModels = true;
env.localModelPath = MODEL_BASE_URL;

// The ONNX Runtime Web WASM files ship inside the app too
// (public/ort/ -> dist/renderer/ort/), NOT from a CDN.
// transformers.js defaults wasmPaths to jsdelivr, which needs
// internet — the v3.3 smoke test caught it failing there even though
// the model files themselves loaded fine from the bundle. The page
// is dist/renderer/index.html, so './ort/' resolves to
// dist/renderer/ort/ in dev (localhost:5173) and in the packaged
// app (file://) alike.
if (env.backends?.onnx?.wasm) {
  env.backends.onnx.wasm.wasmPaths = new URL('./ort/', window.location.href).href;
}

export { EMBED_MODEL_ID };

export type EmbedderState = 'ready' | 'loading' | 'unavailable' | 'not-started';

// eslint-disable-next-line @typescript-eslint/no-explicit-any
let extractor: any = null;
let state: EmbedderState = 'not-started';
let source: EmbedderSource = 'none';
let loadPromise: Promise<void> | null = null;

export function getEmbedderState(): EmbedderState {
  return state;
}

export function getEmbedderSource(): EmbedderSource {
  return source;
}

/**
 * Is the bundled model present? One small fetch of its config — the
 * main process answers dj-model:// from the installed app's resources
 * (404 when the bundle is missing, and the download fallback is used).
 */
async function bundledModelAvailable(): Promise<boolean> {
  try {
    const res = await fetch(modelUrlForFile(EMBED_MODEL_ID, 'config.json'));
    return res.ok;
  } catch {
    return false;
  }
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
      // Bundled first. NOTE: when the bundle is present the browser
      // cache must stay OFF for this load — the Cache API only accepts
      // http(s) keys, and transformers.js would throw trying to cache
      // a dj-model:// response. With the bundle there is nothing to
      // cache anyway. When the bundle is absent the cache stays on,
      // so a hub download is kept for the next launch.
      const bundled = await bundledModelAvailable();
      source = bundled ? 'bundled' : 'downloaded';
      env.useBrowserCache = !bundled;
      reportEmbedderSource();
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
      source = 'none';
    } finally {
      loadPromise = null;
      reportEmbedderState();
      reportEmbedderSource();
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
    source = 'none';
    reportEmbedderState();
    reportEmbedderSource();
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

/** Tell main where the embedder's model came from (bundled / downloaded / none). */
export function reportEmbedderSource(): void {
  if (typeof window !== 'undefined' && window.dj) {
    window.dj.sendEmbedderSource(source);
  }
}
