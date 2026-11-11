// DJ v3 — IPC controllers. Every channel the renderer can call,
// in one place. This is the routes/controllers layer: each handler
// is thin — it checks the input, calls a service, and returns the
// result. The services do the real work.

import { dialog, ipcMain, type BrowserWindow } from 'electron';

import type {
  AppConfig,
  ChatResponse,
  DjStatus,
  DuplicateGroup,
  EmbedResponse,
  IndexCounts,
  OrganizeMove,
  OrganizeRange,
  SearchResult,
} from '../../shared/types';
import { IPC } from '../../shared/ipc';
import type { ConfigRepository } from '../config';
import type { EmbedderClient } from '../services/embedderClient';
import type { IndexService } from '../services/indexService';
import type { ChatService } from '../services/chatService';
import { openApp } from '../services/appLauncher';
import { openFile, openFolder } from '../services/actions';
import { DuplicateService } from '../services/duplicateService';
import { getDownloadsDir, getHomeDir } from '../utils/paths';

export interface ControllerContext {
  /** The app window (may be null before it exists). */
  getWindow: () => BrowserWindow | null;
  configRepo: ConfigRepository;
  indexer: IndexService;
  embedder: EmbedderClient;
  chat: ChatService;
  duplicates: DuplicateService;
}

export function registerIpc(ctx: ControllerContext): void {
  const { indexer, embedder, chat, configRepo } = ctx;

  const enabledFolders = (): string[] =>
    configRepo.load().folders.filter((f) => f.enabled).map((f) => f.path);

  // -- status & config ------------------------------------------------

  ipcMain.handle(IPC.getStatus, (): DjStatus => {
    const config = configRepo.load();
    const { filesIndexed, foldersIndexed, vectorOk } = indexer.status();
    return {
      filesIndexed,
      foldersIndexed,
      vectorOk,
      embedderState: embedder.state,
      embedderSource: embedder.source,
      hasIndex: indexer.hasIndex(),
      indexStale: indexer.indexIsStale(),
      config,
    };
  });

  ipcMain.handle(IPC.getConfig, (): AppConfig => configRepo.load());

  ipcMain.handle(IPC.saveConfig, (_e, config: AppConfig): AppConfig => {
    configRepo.save(config);
    return configRepo.load();
  });

  // -- index ------------------------------------------------------------

  ipcMain.handle(IPC.buildIndex, async (): Promise<IndexCounts> => {
    const folders = enabledFolders();
    return indexer.build(folders);
  });

  // -- search & chat ------------------------------------------------------

  ipcMain.handle(IPC.search, async (_e, query: string): Promise<SearchResult[]> => {
    return indexer.search(query, 8);
  });

  ipcMain.handle(IPC.send, async (_e, text: string): Promise<ChatResponse> => {
    return chat.handle(text);
  });

  // -- organize -------------------------------------------------------------

  ipcMain.handle(IPC.planOrganize, async (_e, range: OrganizeRange): Promise<ChatResponse> => {
    return chat.planOrganize(range);
  });

  ipcMain.handle(
    IPC.applyOrganize,
    async (_e, payload: { plan: OrganizeMove[] }): Promise<ChatResponse> => {
      return chat.applyOrganize(payload.plan);
    },
  );

  // -- duplicates -------------------------------------------------------------

  ipcMain.handle(IPC.findDuplicates, async (): Promise<DuplicateGroup[]> => {
    return ctx.duplicates.find(enabledFolders());
  });

  ipcMain.handle(
    IPC.deleteDuplicates,
    async (
      _e,
      payload: { paths: string[] },
    ): Promise<{ deleted: string[]; errors: string[]; logPath: string }> => {
      return ctx.duplicates.deleteToRecycleBin(payload.paths, getDownloadsDir(getHomeDir()));
    },
  );

  ipcMain.handle(
    IPC.mergeDuplicates,
    async (
      _e,
      payload: { paths: string[]; targetFolder: string },
    ): Promise<{ moved: string[]; errors: string[] }> => {
      return ctx.duplicates.merge(payload.paths, payload.targetFolder);
    },
  );

  // -- open things -------------------------------------------------------------

  ipcMain.handle(IPC.openApp, async (_e, name: string): Promise<{ ok: boolean; message: string }> => {
    return openApp(name);
  });

  ipcMain.handle(IPC.openFile, async (_e, filePath: string): Promise<{ ok: boolean; message: string }> => {
    return openFile(filePath);
  });

  ipcMain.handle(IPC.openFolder, async (_e, folderPath: string): Promise<{ ok: boolean; message: string }> => {
    return openFolder(folderPath);
  });

  ipcMain.handle(IPC.pickFolder, async (): Promise<string | null> => {
    const win = ctx.getWindow();
    if (!win || win.isDestroyed()) return null;
    const result = await dialog.showOpenDialog(win, {
      properties: ['openDirectory'],
    });
    if (result.canceled || result.filePaths.length === 0) return null;
    return result.filePaths[0];
  });

  // -- embedder answers from the renderer --------------------------------------
  // The renderer runs the tiny embedding model. When it answers a
  // request, the reply lands here and is handed to the embedder
  // client, which resolves the waiting promise.

  ipcMain.on(IPC.embedResponse, (_e, resp: EmbedResponse) => {
    embedder.onResponse(resp);
  });

  ipcMain.on(IPC.embedderState, (_e, state: string) => {
    embedder.onRendererState(state);
  });

  ipcMain.on(IPC.embedderSource, (_e, source: string) => {
    embedder.onRendererSource(source);
  });
}
