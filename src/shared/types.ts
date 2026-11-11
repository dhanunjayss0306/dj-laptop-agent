// DJ v3 — shared domain types. Used by the main process, the
// renderer, and the preload script. Nothing here touches Electron,
// Node, or the DOM, so it is safe to import anywhere.

export interface FolderEntry {
  path: string;
  enabled: boolean;
}

export interface AppConfig {
  folders: FolderEntry[];
}

export interface SearchResult {
  path: string;
  name: string;
  folder: string;
  snippet: string;
  score: number;
  /** File size in bytes (Explorer row, right side) — when known. */
  size?: number;
  /** Last-modified date as an ISO string — when known. */
  mtime?: string;
}

/** A folder DJ knows about (recorded at index time, by name). */
export interface IndexedFolder {
  path: string;
  name: string;
  /** The folder this folder lives in. */
  parent: string;
}

export type EmbedderState =
  | 'ready' // meaning search works
  | 'loading' // tiny model is loading inside the app
  | 'unavailable' // embeddings failed; keyword search only
  | 'not-started'; // no index built yet

export interface DjStatus {
  /** Files in the keyword index. */
  filesIndexed: number;
  /** Folders recorded in the index (by name). */
  foldersIndexed: number;
  /** True when meaning search (vectors) is usable. */
  vectorOk: boolean;
  /** The tiny embedding model's state. */
  embedderState: EmbedderState;
  /** True when any index exists at all. */
  hasIndex: boolean;
  /** True when an index exists but was built with an old format. */
  indexStale: boolean;
  /** The current folder config. */
  config: AppConfig;
}

export interface OrganizeMove {
  name: string;
  old: string;
  /** Destination path (never overwrites — gets -1, -2, ...). */
  new: string;
  /** Folder the file goes to, e.g. "Hackathons/Virun-Travel". */
  folder: string;
}

export interface DuplicateFile {
  path: string;
  name: string;
  folder: string;
  mtime: string;
}

export interface DuplicateGroup {
  id: string;
  size: number;
  sizeText: string;
  /** Bytes the extra copies take up. */
  wasted: number;
  files: DuplicateFile[];
}

export type OrganizeRange =
  | { kind: 'today' }
  | { kind: 'yesterday' }
  | { kind: 'lastDays'; days: number }
  | { kind: 'all' };

/** Everything DJ can do with one message. Rules only — no LLM. */
export type ChatAction =
  | { action: 'search'; query: string }
  | { action: 'open'; query: string }
  | { action: 'openFolder'; query: string }
  | { action: 'summarize'; query: string }
  | { action: 'organize'; query: string }
  | { action: 'duplicates'; query: string }
  | { action: 'list'; query: string }
  | { action: 'openApp'; query: string }
  | { action: 'help'; query: string };

/** What the main process sends back for one chat message. */
export type ChatResponse =
  | { kind: 'message'; text: string }
  | { kind: 'search'; text: string; results: SearchResult[] }
  | { kind: 'opened'; text: string; results: SearchResult[] }
  | {
      kind: 'summary';
      text: string;
      fileName: string;
      summary: string;
      note: string;
    }
  | {
      kind: 'organize-plan';
      text: string;
      label: string;
      range: OrganizeRange;
      plan: OrganizeMove[];
    }
  | {
      kind: 'organize-done';
      text: string;
      moved: OrganizeMove[];
      errors: string[];
      logPath: string;
    }
  | { kind: 'duplicates'; text: string; groups: DuplicateGroup[] }
  | {
      kind: 'duplicates-deleted';
      text: string;
      deleted: string[];
      errors: string[];
    }
  | {
      kind: 'duplicates-merged';
      text: string;
      moved: string[];
      errors: string[];
    }
  | { kind: 'ask-range'; text: string }
  | { kind: 'help'; text: string }
  /** Several folders matched — the user picks one. */
  | { kind: 'folders'; text: string; folders: IndexedFolder[] };

export interface IndexProgress {
  stage: 'scan' | 'read' | 'done';
  done: number;
  /** 0 while scanning (total unknown). */
  total: number;
  message: string;
}

export interface IndexCounts {
  files: number;
  folders: number;
  chunks: number;
  embedded: number;
  keywordOnly: number;
  skipped: number;
  errors: number;
  seconds: number;
  vectorOk: boolean;
}

export interface EmbedRequest {
  id: string;
  texts: string[];
  forQuery: boolean;
}

export interface EmbedResponse {
  id: string;
  vectors: number[][] | null;
  error?: string;
}
