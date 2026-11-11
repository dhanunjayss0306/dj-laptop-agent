// DJ v3 — main process entry. Creates the app window, wires the
// services together, and registers the IPC channels. No LLM, no
// server, nothing leaves the laptop.

import * as path from 'path';
import { app, BrowserWindow } from 'electron';

import { ConfigRepository } from './config';
import { registerIpc } from './ipc/ipcControllers';
import { EmbedderClient } from './services/embedderClient';
import { IndexService } from './services/indexService';
import { ChatService } from './services/chatService';
import { DuplicateService } from './services/duplicateService';
import { getDataDir } from './utils/paths';
import { IPC } from '../shared/ipc';
import type { EmbedRequest } from '../shared/types';

const isDev = process.env.NODE_ENV === 'development' || !app.isPackaged;

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
    const devUrl = process.env.VITE_DEV_SERVER_URL ?? 'http://localhost:5173';
    void win.loadURL(devUrl);
    win.webContents.openDevTools({ mode: 'detach' });
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
