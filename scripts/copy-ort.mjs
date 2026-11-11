// DJ v3.3 — copy the ONNX Runtime Web WASM files into public/ort/
// so Vite bundles them into dist/renderer/ort/.
//
// transformers.js defaults its WASM backend path (wasmPaths) to a
// jsdelivr CDN URL, which needs internet. DJ must work fully offline,
// so the app ships these two files itself and the embedder points
// wasmPaths at the local folder (see src/renderer/embedder.ts).
// The files come from the installed @huggingface/transformers
// package — they are a build input, not source, so public/ort/ is
// gitignored and this script re-creates it on every build.
// Run automatically as the "prebuild" npm script.

import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const srcDir = path.join(root, 'node_modules', '@huggingface', 'transformers', 'dist');
const outDir = path.join(root, 'public', 'ort');

const FILES = ['ort-wasm-simd-threaded.jsep.mjs', 'ort-wasm-simd-threaded.jsep.wasm'];

fs.mkdirSync(outDir, { recursive: true });
for (const file of FILES) {
  const src = path.join(srcDir, file);
  if (!fs.existsSync(src)) {
    throw new Error(`copy-ort: missing ${src} — run npm install first`);
  }
  fs.copyFileSync(src, path.join(outDir, file));
}
console.log(`copy-ort: copied ${FILES.length} files to public/ort/`);
