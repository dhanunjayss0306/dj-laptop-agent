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

  registerIpc({
    getWindow: () => mainWindow,
    configRepo,
    indexer,
    embedder,
    chat,
    duplicates,
  });

  mainWindow = createWindow();

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
