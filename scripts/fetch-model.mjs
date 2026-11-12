// DJ v3.4 — download the bundled embedding model (nomic-embed-text-v1.5)
// into resources/models/, so the packaged app works fully offline.
//
// The model files are NOT in git (resources/models/ is gitignored —
// 132 MB of binary). A fresh checkout has no model, so the Store
// build on GitHub Actions runs this script before electron-builder.
//
// Source: ModelScope (modelscope.cn), the mirror that worked when
// Hugging Face was blocked on the build machine. Same files as the
// official nomic-ai/nomic-embed-text-v1.5 repo: config.json,
// tokenizer.json, tokenizer_config.json, special_tokens_map.json,
// onnx/model_quantized.onnx.
//
// Files already on disk with the expected size are skipped, so a
// re-run is cheap. A mismatch (wrong size, bad download) fails
// loudly instead of shipping a broken model.
//
// Run:  node scripts/fetch-model.mjs

import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const MODEL_ID = 'nomic-ai/nomic-embed-text-v1.5';
const BASE = `https://modelscope.cn/models/${MODEL_ID}/resolve/master`;
const OUT = path.join(root, 'resources', 'models', MODEL_ID);

// Expected sizes, measured from the model that shipped in v3.3.0.
// Used to catch a truncated or wrong download.
const FILES = [
  { file: 'config.json', size: 2538 },
  { file: 'tokenizer.json', size: 711396 },
  { file: 'tokenizer_config.json', size: 1191 },
  { file: 'special_tokens_map.json', size: 695 },
  { file: 'onnx/model_quantized.onnx', size: 137296292 },
];

async function download(file, expectedSize) {
  const dest = path.join(OUT, file);
  try {
    const stat = fs.statSync(dest);
    if (stat.size === expectedSize) {
      console.log(`fetch-model: ${file} already present (${stat.size} bytes) — skipping`);
      return;
    }
    console.log(
      `fetch-model: ${file} exists but is ${stat.size} bytes, expected ${expectedSize} — re-downloading`,
    );
  } catch {
    // Missing — download it.
  }
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  const url = `${BASE}/${file}`;
  console.log(`fetch-model: downloading ${file} ...`);
  const res = await fetch(url);
  if (!res.ok) {
    throw new Error(`fetch-model: ${url} answered HTTP ${res.status}`);
  }
  const tmp = `${dest}.tmp`;
  const out = fs.createWriteStream(tmp);
  await new Promise((resolve, reject) => {
    res.body.pipe(out);
    res.body.on('error', reject);
    out.on('finish', resolve);
    out.on('error', reject);
  });
  const got = fs.statSync(tmp).size;
  if (got !== expectedSize) {
    fs.unlinkSync(tmp);
    throw new Error(
      `fetch-model: ${file} downloaded ${got} bytes, expected ${expectedSize} — refusing to keep it`,
    );
  }
  fs.renameSync(tmp, dest);
  console.log(`fetch-model: ${file} OK (${got} bytes)`);
}

for (const { file, size } of FILES) {
  await download(file, size);
}
console.log(`fetch-model: model complete in ${OUT}`);
