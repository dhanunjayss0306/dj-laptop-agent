// DJ v3 — IPC contract between the renderer (React UI) and the main
// process (Node backend). The renderer NEVER touches the file system
// or the embedder directly; it only calls these channels through the
// preload bridge (window.dj). The main process NEVER touches the DOM.

import type {
  AppConfig,
  ChatResponse,
  DjStatus,
  DuplicateGroup,
  EmbedRequest,
  EmbedResponse,
  IndexCounts,
  IndexProgress,
  OrganizeMove,
  OrganizeRange,
  SearchResult,
} from './types';

/** All channels, both directions. Invoke = request/response,
 *  send/on = pushed events. */
export const IPC = {
  getStatus: 'dj:get-status',
  getConfig: 'dj:get-config',
  saveConfig: 'dj:save-config',
  buildIndex: 'dj:build-index',
  search: 'dj:search',
  send: 'dj:send',
  planOrganize: 'dj:plan-organize',
  applyOrganize: 'dj:apply-organize',
  findDuplicates: 'dj:find-duplicates',
  deleteDuplicates: 'dj:delete-duplicates',
  mergeDuplicates: 'dj:merge-duplicates',
  openApp: 'dj:open-app',
  openFile: 'dj:open-file',
  /** Renderer -> main: ask the user to pick a folder to add. */
  pickFolder: 'dj:pick-folder',
  /** Renderer -> main: open a folder in the file manager. */
  openFolder: 'dj:open-folder',
  /** Main -> renderer: index-build progress. */
  indexProgress: 'dj:index-progress',
  /** Main -> renderer: main asks the renderer embedder to embed texts. */
  embedRequest: 'dj:embed-request',
  /** Renderer -> main: the renderer answers an embed request. */
  embedResponse: 'dj:embed-response',
  /** Renderer -> main: the renderer reports embedder state changes. */
  embedderState: 'dj:embedder-state',
} as const;

/** The typed API the preload script exposes as window.dj. */
export interface DjApi {
  getStatus(): Promise<DjStatus>;
  getConfig(): Promise<AppConfig>;
  saveConfig(config: AppConfig): Promise<AppConfig>;
  buildIndex(): Promise<IndexCounts>;
  search(query: string, topN?: number): Promise<SearchResult[]>;
  /** Send one chat message; the main process decides and acts. */
  send(text: string): Promise<ChatResponse>;
  /** Plan an organize for a range. Returns an organize-plan response
   *  (or a plain message when there is nothing to move). */
  planOrganize(range: OrganizeRange): Promise<ChatResponse>;
  /** Carry out a confirmed organize plan. */
  applyOrganize(plan: OrganizeMove[]): Promise<ChatResponse>;
  findDuplicates(): Promise<DuplicateGroup[]>;
  deleteDuplicates(paths: string[]): Promise<{
    deleted: string[];
    errors: string[];
    logPath: string;
  }>;
  mergeDuplicates(
    paths: string[],
    targetFolder: string,
  ): Promise<{ moved: string[]; errors: string[] }>;
  openApp(name: string): Promise<{ ok: boolean; message: string }>;
  openFile(path: string): Promise<{ ok: boolean; message: string }>;
  /** Ask the user to pick a folder (native dialog). Null when cancelled. */
  pickFolder(): Promise<string | null>;
  /** Open a folder in the file manager. */
  openFolder(path: string): Promise<{ ok: boolean; message: string }>;
  /** Index-build progress events. Returns an unsubscribe function. */
  onIndexProgress(cb: (p: IndexProgress) => void): () => void;
  /** Embed requests from main. Returns an unsubscribe function. */
  onEmbedRequest(cb: (req: EmbedRequest) => void): () => void;
  /** Answer one embed request. */
  sendEmbedResponse(resp: EmbedResponse): void;
  /** Report the renderer embedder's state to main. */
  sendEmbedderState(state: string): void;
}

declare global {
  interface Window {
    dj: DjApi;
  }
}
