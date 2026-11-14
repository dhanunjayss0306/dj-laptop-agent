// DJ v3 — shared domain types. Used by the main process, the
// renderer, and the preload script. Nothing here touches Electron,
// Node, or the DOM, so it is safe to import anywhere.

export interface FolderEntry {
  path: string;
  enabled: boolean;
}

export interface AppConfig {
  folders: FolderEntry[];
  /** Optional local model setup (Layer 1). No key, just a local server. */
  localModel?: { kind: 'ollama' | 'lmstudio'; model?: string };
  /** Optional cloud provider (Layer 2). The key lives on this laptop
   *  only, in dj_config.json — it is never sent anywhere except to
   *  the provider the user picked. Leave it out and DJ runs fine. */
  cloud?: { provider: 'openai' | 'openrouter' | 'anthropic'; apiKey?: string };
}

// --- DJ v5.3: three capability layers ------------------------------------
// Layer 0 Core: always on, no model, no key — rules + tiny embeddings.
// Layer 1 Local: an optional local model (Ollama / LM Studio) if running.
// Layer 2 Cloud: an optional provider key. When the model is gone or
// the key expires, DJ falls back down the layers and says so plainly.
// Core file work never depends on Layer 1 or 2.

export type CapabilityLayer = 'core' | 'local' | 'cloud';

export interface LocalModelHealth {
  available: boolean;
  /** e.g. "Ollama (qwen3.5:9b)". */
  name?: string;
  /** Plain reason when not available, e.g. "local model not running". */
  reason?: string;
}

export interface CloudHealth {
  configured: boolean;
  /** true = key works, false = key rejected, null = not checked yet. */
  valid: boolean | null;
  /** Plain reason when not usable, e.g. "cloud key expired (401)". */
  reason?: string;
  statusCode?: number;
}

export interface CapabilityStatus {
  layer: CapabilityLayer;
  local: LocalModelHealth;
  cloud: CloudHealth;
  /** Plain words for the UI, e.g.
   *  "Core only: cloud key expired, local model not running". */
  message: string;
  checkedAt: string;
}

/** One interaction trace (OpenJarvis idea): what ran, how long, what
 *  fell back. Kept in memory only, never sent anywhere. */
export interface TraceRecord {
  id: string;
  at: string;
  route: string;
  tools: string[];
  /** Milliseconds the interaction took. */
  ms: number;
  layer: CapabilityLayer;
  /** What fell back, when it did, e.g. "cloud 401 -> local". */
  fallback?: string;
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
  /** Plain-language note when the file has no readable text
   *  (scanned PDF, locked PDF) — shown with the result. */
  note?: string;
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

/** Where the embedding model that is actually running came from. */
export type EmbedderSource =
  | 'bundled' // shipped inside the installed app — no download
  | 'downloaded' // fetched from the Hugging Face hub on first run
  | 'none'; // no model loaded yet (or it failed)

/** Auto-update state, pushed from the main process to the UI. */
export type UpdateStatus =
  | 'idle' // no check running (or updates off in dev)
  | 'checking' // asking GitHub Releases for a newer version
  | 'available' // a newer version exists; downloading it now
  | 'downloading' // the update file is downloading
  | 'ready' // downloaded — restart DJ to install it
  | 'up-to-date' // already on the newest version
  | 'error'; // the check failed; DJ keeps working as-is

export interface UpdateState {
  status: UpdateStatus;
  /** Plain text for the user, e.g. "Update ready — restart DJ to install". */
  message: string;
  /** The newer version number, when one was found. */
  version?: string;
}

export interface DjStatus {
  /** Files in the keyword index. */
  filesIndexed: number;
  /** Folders recorded in the index (by name). */
  foldersIndexed: number;
  /** True when meaning search (vectors) is usable. */
  vectorOk: boolean;
  /** The tiny embedding model's state. */
  embedderState: EmbedderState;
  /** Where the running embedding model came from (bundled / downloaded / none). */
  embedderSource: EmbedderSource;
  /** True when any index exists at all. */
  hasIndex: boolean;
  /** True when an index exists but was built with an old format. */
  indexStale: boolean;
  /** The current folder config. */
  config: AppConfig;
  /** v5.3: which capability layer is active and why. */
  capability: CapabilityStatus;
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

/** Real system numbers for the System page, read in the main
 *  process from Node's os module. cpuPercent is null when the
 *  system cannot measure it — the UI says so instead of inventing
 *  a number. Disk usage is not included: there is no reliable
 *  built-in call for it on Windows. */
export interface SystemStats {
  /** CPU use in percent, measured from two os.cpus() samples
   *  500 ms apart. Null when it could not be measured. */
  cpuPercent: number | null;
  cpuCores: number;
  totalMemBytes: number;
  freeMemBytes: number;
  /** Seconds since the system booted (os.uptime()). */
  uptimeSeconds: number;
  platform: string;
  checkedAt: string;
}

/** One daily note file (memory/YYYY-MM-DD.md), read-only. */
export interface MemoryDay {
  date: string;
  text: string;
}

/** The v5.3 memory files, read-only for the Memory page. */
export interface MemoryContent {
  memoryMd: string;
  daily: MemoryDay[];
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
  /** Files unchanged since the last build — chunks/vectors reused. */
  reused?: number;
  /** Files read fresh this build (not reused). */
  new?: number;
  /** Files in the old index that are gone now. */
  removed?: number;
  /** Names of files skipped as unreadable or too slow (first 20). */
  skippedNames?: string[];
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
