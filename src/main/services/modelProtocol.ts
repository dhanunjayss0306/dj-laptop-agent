// DJ v3.3 — serves the bundled embedding model to the renderer.
//
// The renderer (Chromium) loads the tiny model with fetch(), through
// transformers.js env.localModelPath. The main process answers the
// private dj-model:// scheme with files from the bundled model folder:
//   packaged app: <install dir>/resources/models/nomic-embed-text-v1.5/
//   dev (npm run dev): <repo>/resources/models/nomic-embed-text-v1.5/
// No server, no port, nothing leaves the laptop. If a file is missing
// the handler answers 404, and transformers.js falls back to
// downloading the same model from the Hugging Face hub.

import * as fs from 'fs';
import * as path from 'path';
import { Readable } from 'stream';
import { app, protocol } from 'electron';

import {
  BUNDLED_MODEL_DIR_NAME,
  MODEL_PROTOCOL,
} from '../../shared/modelSource';

/** Folder holding every bundled model (one folder per model). */
export function getBundledModelsDir(): string {
  if (app.isPackaged) {
    return path.join(process.resourcesPath, 'models');
  }
  return path.join(app.getAppPath(), 'resources', 'models');
}

/** Folder of the one model DJ ships. */
export function getBundledModelDir(): string {
  return path.join(getBundledModelsDir(), BUNDLED_MODEL_DIR_NAME);
}

/**
 * Resolve a dj-model:// request path to a file inside the models
 * folder. Returns null for anything outside the folder (a path
 * traversal attempt) or for a file that is not there.
 */
export function resolveModelFile(modelsDir: string, urlPath: string): string | null {
  const prefix = '/models/';
  if (!urlPath.startsWith(prefix)) return null;
  let rel: string;
  try {
    rel = decodeURIComponent(urlPath.slice(prefix.length));
  } catch {
    return null;
  }
  const resolved = path.resolve(modelsDir, rel);
  if (resolved !== modelsDir && !resolved.startsWith(modelsDir + path.sep)) return null;
  try {
    if (!fs.statSync(resolved).isFile()) return null;
  } catch {
    return null;
  }
  return resolved;
}

/**
 * Register the scheme as privileged. MUST run before app.ready —
 * main.ts calls it at module level.
 */
export function registerModelSchemePrivileges(): void {
  protocol.registerSchemesAsPrivileged([
    {
      scheme: MODEL_PROTOCOL,
      privileges: {
        standard: true,
        secure: true,
        supportFetchAPI: true,
        corsEnabled: true,
      },
    },
  ]);
}

/**
 * Turn a dj-model:// request URL into the '/models/...' path
 * resolveModelFile expects. In a standard-scheme URL the part after
 * '://' is the HOST, so for 'dj-model://models/nomic-ai/...' the
 * pathname alone is '/nomic-ai/...' — the 'models' segment lives in
 * url.host. Returns null for a URL that is not for this scheme's
 * models folder.
 */
export function modelRequestPath(reqUrl: string): string | null {
  let url: URL;
  try {
    url = new URL(reqUrl);
  } catch {
    return null;
  }
  if (url.protocol !== `${MODEL_PROTOCOL}:`) return null;
  if (url.host !== 'models' || !url.pathname || url.pathname === '/') return null;
  return `/${url.host}${url.pathname}`;
}

/**
 * Build the HTTP response for one model file, streamed from disk
 * with a real Content-Length. That header matters: without it,
 * transformers.js cannot pre-allocate the download buffer and has
 * to keep expanding it while a 137 MB model streams in, which makes
 * the first load far slower (the v3.3 smoke test watched it run
 * into the 120 s embed timeout). Returns null for a missing file
 * or a directory.
 */
export function buildModelFileResponse(file: string): Response | null {
  let stat: fs.Stats;
  try {
    stat = fs.statSync(file);
    if (!stat.isFile()) return null;
  } catch {
    return null;
  }
  const headers = new Headers({
    'Content-Length': String(stat.size),
    'Content-Type': file.endsWith('.json') ? 'application/json' : 'application/octet-stream',
  });
  return new Response(Readable.toWeb(fs.createReadStream(file)) as ReadableStream, {
    status: 200,
    headers,
  });
}

/** Serve model files. Call once, after app.ready. */
export function registerModelProtocol(modelsDir: string): void {
  protocol.handle(MODEL_PROTOCOL, async (req) => {
    const path = modelRequestPath(req.url);
    if (!path) return new Response('bad model request', { status: 400 });
    const file = resolveModelFile(modelsDir, path);
    if (!file) return new Response('model file not found', { status: 404 });
    return buildModelFileResponse(file) ?? new Response('model file could not be read', { status: 500 });
  });
}
