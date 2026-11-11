// DJ v3.3 tests — the bundled embedding model: URL building and the
// file-serving guard. The real protocol runs in the app; these tests
// check the pure parts: the dj-model:// URL shape and that a request
// can only ever resolve to a file inside the models folder.

import { execSync } from 'child_process';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { describe, expect, it } from 'vitest';

import { modelUrlForFile } from '../src/shared/modelSource';
import {
  buildModelFileResponse,
  modelRequestPath,
  resolveModelFile,
} from '../src/main/services/modelProtocol';

describe('modelRequestPath: the URL host is part of the path', () => {
  it('keeps the "models" host segment — a dj-model:// URL puts it in host, not pathname', () => {
    // This is the exact bug found in the v3.3 smoke test: passing
    // url.pathname alone dropped the "models" segment, so every
    // bundled-model request 404'd and the app fell back to a
    // (blocked) Hugging Face download.
    expect(
      modelRequestPath('dj-model://models/nomic-ai/nomic-embed-text-v1.5/config.json'),
    ).toBe('/models/nomic-ai/nomic-embed-text-v1.5/config.json');
    expect(
      modelRequestPath(
        'dj-model://models/nomic-ai/nomic-embed-text-v1.5/onnx/model_quantized.onnx',
      ),
    ).toBe('/models/nomic-ai/nomic-embed-text-v1.5/onnx/model_quantized.onnx');
  });
  it('rejects URLs that are not for the models folder', () => {
    expect(modelRequestPath('dj-model://other/nomic-ai/config.json')).toBeNull();
    expect(modelRequestPath('dj-model://models/')).toBeNull();
    expect(modelRequestPath('https://huggingface.co/nomic-ai/config.json')).toBeNull();
    expect(modelRequestPath('not a url')).toBeNull();
  });
  it('a full request URL round-trips to the real file', () => {
    const { dir, modelFile } = makeModelsDir();
    const path = modelRequestPath(
      modelUrlForFile('nomic-ai/nomic-embed-text-v1.5', 'onnx/model_quantized.onnx'),
    );
    expect(path).not.toBeNull();
    expect(resolveModelFile(dir, path as string)).toBe(modelFile);
  });
});

describe('modelUrlForFile: the renderer fetches the model here', () => {
  it('builds a dj-model:// URL under the model id', () => {
    expect(modelUrlForFile('nomic-ai/nomic-embed-text-v1.5', 'config.json')).toBe(
      'dj-model://models/nomic-ai/nomic-embed-text-v1.5/config.json',
    );
    expect(
      modelUrlForFile('nomic-ai/nomic-embed-text-v1.5', 'onnx/model_quantized.onnx'),
    ).toBe('dj-model://models/nomic-ai/nomic-embed-text-v1.5/onnx/model_quantized.onnx');
  });
});

describe('buildModelFileResponse: a real Content-Length', () => {
  it('serves the file with its exact size, so the loader can pre-allocate', async () => {
    const { dir, modelFile } = makeModelsDir();
    const res = buildModelFileResponse(modelFile);
    expect(res).not.toBeNull();
    expect(res?.status).toBe(200);
    expect(res?.headers.get('Content-Length')).toBe('2');
    expect(res?.headers.get('Content-Type')).toBe('application/octet-stream');
    expect(Buffer.from(await res!.arrayBuffer())).toEqual(Buffer.from([0x08, 0x07]));
    expect(buildModelFileResponse(path.join(dir, 'missing.bin'))).toBeNull();
    expect(buildModelFileResponse(dir)).toBeNull();
    const jsonRes = buildModelFileResponse(path.join(dir, 'nomic-ai', 'nomic-embed-text-v1.5', 'config.json'));
    expect(jsonRes?.headers.get('Content-Type')).toBe('application/json');
  });
});

function makeModelsDir(): { dir: string; modelFile: string } {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-models-'));
  // The real layout nests the model under its org, exactly like the
  // model id: models/nomic-ai/nomic-embed-text-v1.5/...
  const modelDir = path.join(dir, 'nomic-ai', 'nomic-embed-text-v1.5', 'onnx');
  fs.mkdirSync(modelDir, { recursive: true });
  const modelFile = path.join(modelDir, 'model_quantized.onnx');
  fs.writeFileSync(modelFile, Buffer.from([0x08, 0x07]));
  fs.writeFileSync(path.join(dir, 'nomic-ai', 'nomic-embed-text-v1.5', 'config.json'), '{}');
  return { dir, modelFile };
}

describe('resolveModelFile: only files inside the models folder', () => {
  it('resolves a real model file', () => {
    const { dir, modelFile } = makeModelsDir();
    expect(
      resolveModelFile(
        dir,
        '/models/nomic-ai/nomic-embed-text-v1.5/onnx/model_quantized.onnx',
      ),
    ).toBe(modelFile);
  });
  it('returns null for a missing file (the renderer then downloads instead)', () => {
    const { dir } = makeModelsDir();
    expect(resolveModelFile(dir, '/models/nomic-ai/nomic-embed-text-v1.5/config.json')).not.toBeNull();
    expect(resolveModelFile(dir, '/models/nomic-ai/nomic-embed-text-v1.5/nope.json')).toBeNull();
    expect(resolveModelFile(dir, '/models/other-model/config.json')).toBeNull();
  });
  it('refuses path traversal outside the models folder', () => {
    const { dir } = makeModelsDir();
    expect(
      resolveModelFile(dir, '/models/nomic-embed-text-v1.5/../../secret.txt'),
    ).toBeNull();
    expect(resolveModelFile(dir, '/models/%2e%2e/%2e%2e/secret.txt')).toBeNull();
    expect(resolveModelFile(dir, '/etc/passwd')).toBeNull();
    expect(resolveModelFile(dir, '/models/../secret.txt')).toBeNull();
  });
  it('refuses a directory, not just a missing file', () => {
    const { dir } = makeModelsDir();
    expect(resolveModelFile(dir, '/models/nomic-embed-text-v1.5/onnx')).toBeNull();
  });
});

describe('bundled ONNX Runtime Web files: no CDN at runtime', () => {
  it('the WASM backend files ship inside the app', () => {
    // transformers.js defaults wasmPaths to a jsdelivr CDN URL, which
    // needs internet. The v3.3 smoke test caught the model load
    // failing on that fetch even though the model files themselves
    // loaded fine from the bundle. The copy-ort build step copies
    // both files from the installed package into public/ort/, and
    // Vite copies them into dist/renderer/ort/.
    const root = path.join(__dirname, '..');
    execSync('node scripts/copy-ort.mjs', { cwd: root, stdio: 'ignore' });
    for (const file of [
      'ort-wasm-simd-threaded.jsep.mjs',
      'ort-wasm-simd-threaded.jsep.wasm',
    ]) {
      expect(fs.existsSync(path.join(root, 'public', 'ort', file))).toBe(true);
    }
  });
  it('the embedder points the WASM backend at the local folder', () => {
    const embedder = fs.readFileSync(
      path.join(__dirname, '..', 'src', 'renderer', 'embedder.ts'),
      'utf8',
    );
    expect(embedder).toContain('wasmPaths');
    expect(embedder).toContain('./ort/');
    expect(embedder).not.toContain('cdn.jsdelivr.net');
  });
});
