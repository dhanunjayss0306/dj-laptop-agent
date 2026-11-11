// DJ v3 — preload. The only bridge between the web page and the
// main process. The page gets exactly `window.dj` — nothing else.
// (contextIsolation on, nodeIntegration off.)

import { contextBridge, ipcRenderer, type IpcRendererEvent } from 'electron';

import { IPC, type DjApi } from '../shared/ipc';
import type {
  EmbedRequest,
  EmbedResponse,
  IndexProgress,
  UpdateState,
} from '../shared/types';

const api: DjApi = {
  getStatus: () => ipcRenderer.invoke(IPC.getStatus),
  getConfig: () => ipcRenderer.invoke(IPC.getConfig),
  saveConfig: (config) => ipcRenderer.invoke(IPC.saveConfig, config),
  buildIndex: () => ipcRenderer.invoke(IPC.buildIndex),
  search: (query) => ipcRenderer.invoke(IPC.search, query),
  send: (text) => ipcRenderer.invoke(IPC.send, text),
  planOrganize: (range) => ipcRenderer.invoke(IPC.planOrganize, range),
  applyOrganize: (plan) => ipcRenderer.invoke(IPC.applyOrganize, { plan }),
  findDuplicates: () => ipcRenderer.invoke(IPC.findDuplicates),
  deleteDuplicates: (paths) => ipcRenderer.invoke(IPC.deleteDuplicates, { paths }),
  mergeDuplicates: (paths, targetFolder) =>
    ipcRenderer.invoke(IPC.mergeDuplicates, { paths, targetFolder }),
  openApp: (name) => ipcRenderer.invoke(IPC.openApp, name),
  openFile: (filePath) => ipcRenderer.invoke(IPC.openFile, filePath),
  pickFolder: () => ipcRenderer.invoke(IPC.pickFolder),
  openFolder: (folderPath) => ipcRenderer.invoke(IPC.openFolder, folderPath),

  onIndexProgress: (cb) => {
    const listener = (_e: IpcRendererEvent, p: IndexProgress): void => cb(p);
    ipcRenderer.on(IPC.indexProgress, listener);
    return () => {
      ipcRenderer.removeListener(IPC.indexProgress, listener);
    };
  },

  onEmbedRequest: (cb) => {
    const listener = (_e: IpcRendererEvent, req: EmbedRequest): void => cb(req);
    ipcRenderer.on(IPC.embedRequest, listener);
    return () => {
      ipcRenderer.removeListener(IPC.embedRequest, listener);
    };
  },

  sendEmbedResponse: (resp: EmbedResponse) => {
    ipcRenderer.send(IPC.embedResponse, resp);
  },

  sendEmbedderState: (state: string) => {
    ipcRenderer.send(IPC.embedderState, state);
  },

  sendEmbedderSource: (source: string) => {
    ipcRenderer.send(IPC.embedderSource, source);
  },

  onUpdateStatus: (cb) => {
    const listener = (_e: IpcRendererEvent, s: UpdateState): void => cb(s);
    ipcRenderer.on(IPC.updateStatus, listener);
    return () => {
      ipcRenderer.removeListener(IPC.updateStatus, listener);
    };
  },
};

contextBridge.exposeInMainWorld('dj', api);
