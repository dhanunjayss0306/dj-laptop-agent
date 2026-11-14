// DJ v3 — main process entry. Creates the app window, wires the
// services together, and registers the IPC channels. No LLM, no
// server, nothing leaves the laptop.

import * as path from 'path';
import { app, BrowserWindow, Menu } from 'electron';

import { ConfigRepository } from './config';
import { registerIpc } from './ipc/ipcControllers';
import { EmbedderClient } from './services/embedderClient';
import { IndexService } from './services/indexService';
import { ChatService } from './services/chatService';
import { DuplicateService } from './services/duplicateService';
import {
  getBundledModelsDir,
  registerModelProtocol,
  registerModelSchemePrivileges,
} from './services/modelProtocol';
import { UpdateService } from './services/updateService';
import { getDataDir } from './utils/paths';
import { IPC } from '../shared/ipc';
import type { EmbedRequest, UpdateState } from '../shared/types';
// DJ v5.3 — capability layers (cloud / local / core) and the
// OpenClaw heartbeat + memory files. The probes below are the only
// network calls DJ makes for layers, and they never send the key
// anywhere except to the provider the user picked.
import {
  CapabilityManager,
  isAuthError,
  type CapabilityProbes,
} from './v53/capability';
import { defaultPrimitives, TraceStore } from './v53/primitives';
import { Heartbeat, MemoryFiles } from './v53/agentLoop';
import type { CloudHealth, LocalModelHealth } from '../shared/types';

const isDev = process.env.NODE_ENV === 'development' || !app.isPackaged;

// The bundled model is served on a private scheme — privileges must
// be registered before the app is ready.
registerModelSchemePrivileges();

let mainWindow: BrowserWindow | null = null;

function createWindow(): BrowserWindow {
  const win = new BrowserWindow({
    width: 880,
    height: 720,
    title: 'DJ — your files, found',
    webPreferences: {
      preload: path.join(__dirname, '..', 'preload', 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  });

  if (isDev) {
    // In development the window loads the Vite dev server. But `npm
    // start` runs `electron .` WITHOUT the dev server — the window
    // used to come up blank (chrome-error://chromewebdata/). So when
    // the dev server fails to load, fall back to the built file
    // (dist/renderer/index.html) instead of staying blank.
    const builtFile = path.join(__dirname, '..', 'renderer', 'index.html');
    const devUrl = process.env.VITE_DEV_SERVER_URL ?? 'http://localhost:5173';
    win.webContents.once('did-fail-load', () => {
      void win.loadFile(builtFile);
    });
    void win.loadURL(devUrl);
  } else {
    // Production: dist/main/main.js -> dist/renderer/index.html.
    void win.loadFile(path.join(__dirname, '..', 'renderer', 'index.html'));
  }

  win.on('closed', () => {
    mainWindow = null;
  });
  return win;
}

// -- DJ v5.3 layer probes (main process only) -------------------------
// Layer 1: ask Ollama, then LM Studio, whether a model is up. Each
// gets 1.5 s; a dead server is "not running", never a hang.
// Layer 2: ask the configured provider whether the key still works
// (GET /v1/models). 200 = valid; 401/403 = expired or invalid, and
// DJ falls back instead of retrying. The key is only ever sent to
// the provider the user picked, and never logged.

async function checkLocalModel(): Promise<LocalModelHealth> {
  const servers: Array<{ name: string; url: string }> = [
    { name: 'Ollama', url: 'http://127.0.0.1:11434/api/tags' },
    { name: 'LM Studio', url: 'http://127.0.0.1:1234/v1/models' },
  ];
  for (const server of servers) {
    try {
      const res = await fetch(server.url, { signal: AbortSignal.timeout(1500) });
      if (!res.ok) continue;
      const data = (await res.json()) as {
        models?: Array<{ name?: string; id?: string }>;
      };
      const first = data.models?.[0];
      if (first) return { available: true, name: `${server.name} (${first.name ?? first.id ?? 'model'})` };
      return { available: true, name: server.name };
    } catch {
      // Server not answering — try the next one.
    }
  }
  return { available: false, reason: 'local model not running' };
}

async function checkCloudKey(
  loadConfig: () => { cloud?: { provider: 'openai' | 'openrouter' | 'anthropic'; apiKey?: string } },
): Promise<CloudHealth> {
  const cloud = loadConfig().cloud;
  if (!cloud?.apiKey) {
    return { configured: false, valid: null, reason: 'no cloud key set' };
  }
  const bases: Record<string, string> = {
    openai: 'https://api.openai.com/v1',
    openrouter: 'https://openrouter.ai/api/v1',
    anthropic: 'https://api.anthropic.com/v1',
  };
  const headers: Record<string, string> =
    cloud.provider === 'anthropic'
      ? {
          'x-api-key': cloud.apiKey,
          'anthropic-version': '2023-06-01',
        }
      : { Authorization: `Bearer ${cloud.apiKey}` };
  try {
    const res = await fetch(`${bases[cloud.provider]}/models`, {
      headers,
      signal: AbortSignal.timeout(2000),
    });
    if (res.ok) return { configured: true, valid: true };
    if (isAuthError(res.status)) {
      return {
        configured: true,
        valid: false,
        statusCode: res.status,
        reason: `cloud key expired or invalid (${res.status})`,
      };
    }
    return {
      configured: true,
      valid: null,
      statusCode: res.status,
      reason: 'cloud could not be checked',
    };
  } catch {
    return { configured: true, valid: null, reason: 'cloud could not be checked' };
  }
}

async function main(): Promise<void> {
  await app.whenReady();

  // DJ has no use for Electron's default File / Edit / View /
  // Window / Help menu bar — a clean chat app has no menu at all.
  // DevTools is still available with Ctrl+Shift+I.
  Menu.setApplicationMenu(null);

  // Serve the bundled embedding model to the renderer (dj-model://).
  // A missing file answers 404 and the renderer falls back to a
  // Hugging Face download instead.
  registerModelProtocol(getBundledModelsDir());

  const dataDir = getDataDir();
  const configRepo = new ConfigRepository(dataDir);

  // The embedder runs in the renderer (WASM ONNX). Main asks it
  // over IPC; this callback is how main sends the request.
  const embedder = new EmbedderClient((req: EmbedRequest): boolean => {
    const win = mainWindow;
    if (!win || win.isDestroyed()) return false;
    win.webContents.send(IPC.embedRequest, req);
    return true;
  });

  const indexer = new IndexService(dataDir, embedder, (p) => {
    const win = mainWindow;
    if (win && !win.isDestroyed()) {
      win.webContents.send(IPC.indexProgress, p);
    }
  });
  indexer.loadFromDisk();

  const chat = new ChatService(indexer, () =>
    configRepo.load().folders.filter((f) => f.enabled).map((f) => f.path),
  );
  const duplicates = new DuplicateService();

  // -- DJ v5.3: capability layers -------------------------------------
  // Layer 1 probe: is a local model server answering? Ollama first,
  // then LM Studio. A short timeout each — a dead server must not
  // hang startup. Layer 2 probe: is a cloud key set, and does it
  // still work? A 401/403 means expired/invalid, and DJ falls back
  // instead of retrying. Neither probe is required for Core: file
  // search, open, delete, and organise work with both of them down.
  const probes: CapabilityProbes = {
    checkLocal: () => checkLocalModel(),
    checkCloud: () => checkCloudKey(() => configRepo.load()),
  };
  const capability = new CapabilityManager(probes);
  const primitives = defaultPrimitives();
  const traces = new TraceStore(primitives.learning.maxTraces);
  const memoryFiles = new MemoryFiles(dataDir);

  registerIpc({
    getWindow: () => mainWindow,
    configRepo,
    indexer,
    embedder,
    chat,
    duplicates,
    capability,
    dataDir,
  });

  mainWindow = createWindow();

  // v5.3 heartbeat (OpenClaw idea): every 30 minutes re-check the
  // layers. Only a CHANGE is noted — in the trace store and in
  // today's daily note — so the heartbeat never spams the user.
  // It never acts on files by itself.
  let lastLayer = (await capability.resolve()).layer;
  const heartbeat = new Heartbeat(30 * 60 * 1000, async () => {
    const status = await capability.resolve(true);
    if (status.layer !== lastLayer) {
      traces.record({
        route: 'capability-check',
        tools: [],
        ms: 0,
        layer: status.layer,
        fallback: `${lastLayer} -> ${status.layer}`,
      });
      memoryFiles.appendDaily(`Layer changed: ${lastLayer} -> ${status.layer} (${status.message})`);
      lastLayer = status.layer;
    }
  });
  heartbeat.start();
  app.on('before-quit', () => heartbeat.stop());

  // Self-update from GitHub Releases (installed app only — in dev
  // the service stays idle, and in the Microsoft Store build it stays
  // idle too, because the Store updates the app itself). Checks on
  // startup and once a day, downloads in the background, installs when
  // DJ quits. Never restarts the app by itself; the UI shows the update
  // state.
  const updater = new UpdateService((s: UpdateState) => {
    const win = mainWindow;
    if (win && !win.isDestroyed()) {
      win.webContents.send(IPC.updateStatus, s);
    }
  });
  void updater.start(app.isPackaged, Boolean(process.windowsStore));

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      mainWindow = createWindow();
    }
  });
}

app.on('window-all-closed', () => {
  // On Windows, closing the window quits the app.
  if (process.platform !== 'darwin') app.quit();
});

void main();
