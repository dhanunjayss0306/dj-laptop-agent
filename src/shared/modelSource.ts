// DJ v3.3 — where the tiny embedding model comes from. Shared by
// the main process (which serves the files) and the renderer (which
// loads them). No Electron imports here, so it is safe anywhere.
//
// The model is nomic-embed-text-v1.5, the official nomic-ai repo
// (transformers.js 3.8 understands its `nomic_bert` config natively).
// It ships INSIDE the installed app, under resources/models/ — the
// main process answers the private dj-model:// scheme with those
// files, and the renderer loads them with fetch() through
// env.localModelPath. If the bundled copy is missing, transformers.js
// falls back to downloading the same repo from the Hugging Face hub.

export const EMBED_MODEL_ID = 'nomic-ai/nomic-embed-text-v1.5';

/**
 * Relative folder of the bundled model, under resources/models/.
 * It matches the model id exactly, so a dj-model:// URL maps 1:1
 * onto disk: dj-model://models/<this>/config.json is
 * resources/models/<this>/config.json. That is also how
 * transformers.js lays out a local model (localModelPath + model id).
 */
export const BUNDLED_MODEL_DIR_NAME = 'nomic-ai/nomic-embed-text-v1.5';

/** Private scheme the main process serves model files on. */
export const MODEL_PROTOCOL = 'dj-model';

/** Base URL transformers.js uses as env.localModelPath. */
export const MODEL_BASE_URL = `${MODEL_PROTOCOL}://models/`;

/** The URL the renderer fetches one model file from. */
export function modelUrlForFile(modelId: string, file: string): string {
  return `${MODEL_BASE_URL}${modelId}/${file}`;
}
