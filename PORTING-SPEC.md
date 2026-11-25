# DJ — Flutter Porting Spec

**Source read:** `~/workspace/dj-app/src/` (Electron + TypeScript + React, version **5.6.0**,
`package.json`: name `dj-app`, appId `com.dhanunjay.dj`, product name `DJ`, Store identity
`DJservices.DJfiles`, GitHub repo `dhanunjayss0306/dj-laptop-agent`).
**Target:** rebuild DJ in Flutter (Dart), Windows-first. **Read-only analysis — no file in
`~/workspace/dj-app/` was modified. No commit, no push, no token used.**
**Total source surveyed:** 51 files under `src/`, ~8,921 lines, plus 17 test files in
`~/workspace/dj-app/tests/` (use them as the regression oracle for the port).

> The single most important fact for the Flutter builders: **DJ's shipped behaviour is
> Core-only and rules-only.** The chat brain, search, summarize, organize, duplicates and
> open-app logic need no model and no key. The Cloud/Local layers in §3 are *health probes
> and status display only* — no code in the shipped app actually sends a chat prompt to
> Ollama, LM Studio, OpenAI, OpenRouter or Anthropic. Do not build the Flutter port
> assuming a working LLM chat exists to port. Port the probes and the status UI; treat
> real LLM chat as a future feature, not a ported one.

---

## 0. Architecture map (Electron → Flutter)

| Electron piece | File(s) | Flutter equivalent (target) |
|---|---|---|
| Main process (Node, owns FS, OS, config, index) | `src/main/main.ts`, `src/main/ipc/ipcControllers.ts`, `src/main/services/*` | Dart service layer (plain Dart classes, no UI). Must run off the UI thread for index builds / hashing — use isolates. |
| Renderer (React UI) | `src/renderer/App.tsx`, `src/renderer/components/*` | Flutter widgets, one widget per page/component in §1.5. |
| Preload bridge (`window.dj`) | `src/preload/preload.ts` | **Delete this layer.** In Flutter the UI calls the Dart service layer directly (same-process method calls, not IPC). Keep the *method list* in §6 as the service API — same names, same inputs/outputs, same return types. |
| Shared types | `src/shared/types.ts`, `src/shared/ipc.ts`, `src/shared/modelSource.ts` | Dart model classes (freezed / plain classes with `fromJson`/`toJson`). Field names must match §5 exactly so stored JSON files stay compatible. |
| Embedding model runner (renderer, WASM ONNX) | `src/renderer/embedder.ts` | See §5.4 — the hard part of the port. No direct Dart equivalent of transformers.js; needs `onnxruntime` (Dart/Flutter ONNX Runtime package) or a platform channel. |
| Private model-serving scheme | `src/main/services/modelProtocol.ts` (`dj-model://`) | Delete. In Flutter, bundle the model as an asset / app-support file and load it from disk. |

**App entry — `src/main/main.ts`:**
- Window 880 × 720, title `DJ — your files, found`. No application menu
  (`Menu.setApplicationMenu(null)`); DevTools still available via Ctrl+Shift+I.
- Dev: loads Vite dev server `http://localhost:5173`, falls back to built
  `dist/renderer/index.html` on `did-fail-load`. Packaged: loads the built file.
- `app.whenReady()` order: register model protocol → load config → apply
  start-at-login (packaged only) → create `EmbedderClient` (callback sends
  `dj:embed-request` to the window) → create `IndexService`, `loadFromDisk()` →
  create `ChatService`, `DuplicateService` → create `CapabilityManager` with probes
  → `TraceStore(200)`, `MemoryFiles(dataDir)` → `registerIpc(...)` → `createWindow()`
  → create tray (if an icon file exists) → start 30-minute `Heartbeat` → start
  `UpdateService` → `app.on('activate')` re-shows a tray-hidden window.
- `window-all-closed`: on non-macOS, quit **only if there is no tray**
  (`tray === null`); with a tray the app keeps running hidden.

**Data directory — `src/main/utils/paths.ts`:**
`getDataDir()` = `app.getPath('userData') + '/dj_data'` (on Windows:
`%APPDATA%\DJ\dj_data`). All index/config/memory files live there (see §5.5).
Config file is `dj_config.json` in that folder. **An update must never touch this
folder** (update installs on quit; data survives).

---

## 1. Every user-facing feature

### 1.1 Chat / Command Center (default page, `src/renderer/App.tsx`)

- Welcome message shown on first load (verbatim):
  > "Hi, I'm DJ. I find your files on this laptop — by name or by what is inside them. Try \"find my Virun pitch\", \"open the frontend folder\", \"summarize my Virun pitch\", \"organize yesterday's Downloads\", \"find duplicates\", or \"open notepad\". Summaries are picked from the file itself, no AI."
- One text composer at the bottom, placeholder
  `Find a file, open a folder, organize Downloads...`, Send button. Send disabled
  while busy or when input is blank. User messages right-aligned; DJ replies
  left-aligned, full width. `DJ is working...` indicator while busy. Chat
  auto-scrolls to the newest message.
- One message → one `ChatResponse` (§6). The brain is `BrainService.decide()`
  (`src/main/services/brainService.ts`) — pure keyword/pattern rules, no model.
  Routing order (first match wins):
  1. Empty text → `help`. `help` / `what can you do` / `help me` → `help`.
  2. Contains `duplicat` / `extra cop` / `same file` → `duplicates`; if it also
     contains `merge` the query is `'merge'`; else if it contains `delet` the
     query is `'delete'`; else `''`.
  3. Contains `organiz` → `organize`, range parsed by `parseOrganizeRangeText()`.
  4. Contains `summar` → `summarize`, query = text after `summarize this file` /
     `summarise this file` / `summarize` / `summarise` / `summary of`.
  5. Contains the word `folder`/`folders`/`directory`/`directories` →
     `openFolder`, name extracted by `extractFolderQuery()` (name between the last
     verb `open|find|show|go to|go` and `folder`; `folder in <project>` adds the
     project; no name → `''`, which makes chat list known folders).
  6. Starts with `open ` → strip `something|anything|all the things|the files?|a file`
     + `about|on|related to`; if the remainder is a known app (§1.7) → `openApp`;
     else if it is a known folder name → `openFolder`; else `open`.
  7. Starts with `find ` / `search for ` / `search ` / `look for ` / `where is ` /
     `where are ` / `show me ` → `search` (or `openFolder` if it names a known folder).
  8. Starts with `list ` / `show ` → `list`.
  9. Default: `search` with the raw text as the query.
- `HELP_TEXT` (verbatim, `brainService.ts`): lists find / open-by-topic /
  open-folder / open-file-in-project / summarize / organize (today, yesterday,
  last 3 days, this week, everything) / find duplicates / delete extra copies /
  merge extra copies / open notepad / list recent files.
- Chat actions and their exact behaviour (`ChatService.handle()`,
  `src/main/services/chatService.ts`):
  - `search`: `splitFolderHint()` splits `"index.html in AuPro"` into query
    `index.html` + hint `AuPro`; `preferInFolder()` moves results whose folder or
    path contains the hint to the front. Top 8 results (`indexer.search(query, 8)`).
    No results → message `I could not find anything about '<query>' in your folders.`
    + meaning note (see below) + `Try different words, or click Rebuild index if
    you added files recently.` + `HELP_TEXT`.
  - `open`: search top 8, open `results[0]` with the OS default app; reply kind
    `opened`, text `Opened <name>.` (or the open error + `Here is what I found instead:`).
    No results → `I could not find a file about '<query>'.`
  - `openFolder`: `indexer.findFolders(query)`; 0 matches → if no folders are known
    at all: `I don't know a folder called '<query>' yet — I only learn folder names
    when the index is built. Click Rebuild index once, then ask again.`; otherwise
    lists up to 12 known folders (`• <name> — <path>`). 1 match → open in Explorer.
    Several matches → kind `folders`, user picks one (UI renders a pick list).
  - `summarize`: search top 3, take `results[0]`, read its text (max 8,000 chars
    via `getFileText(path, 8000)`), `summarizeText()` (§1.6). Reply kind `summary`
    with `fileName`, `summary`, `note` (see §1.6 for the exact note wording).
    No file → `I could not find a file about '<query>' to summarize.`
  - `organize`: `parseOrganizeRange()`; no range recognised → kind `ask-range`,
    text `Which days should I organize in Downloads?` (UI shows Today / Yesterday /
    Last 3 days / Last 7 days / All buttons). Otherwise returns the plan (§1.4).
  - `duplicates`: `DuplicateService.find(enabled folders)`; 0 groups →
    `I found no extra copies in your folders.` Otherwise kind `duplicates`, text
    `I found <N> group(s) of extra copies (<M> extra file(s)).` + hint:
    delete → ` Tick the copies you want rid of, then click Delete selected copies — they go to the Recycle Bin, only after you confirm.`;
    merge → ` Pick a folder below and click Merge — I will keep one copy where it is and move the rest there.`;
    else → ` The first copy in each group is always kept.`
  - `list`: `indexer.listRecent(10)` → kind `search`, text `Here are your newest indexed files:`,
    results with empty snippet and score 0. No index → `I have not indexed any files yet. Click Rebuild index first.`
  - `openApp`: `openApp(query)` → plain message with its result text.
  - Meaning note appended to search/open replies (`ChatService.meaningNote()`):
    embedder loading → `\n\nMeaning search is still loading — these are keyword matches for now.`;
    unavailable → `\n\nMeaning search is unavailable right now — these are keyword matches.`;
    ready → nothing.
- **No free-form chat.** Anything that is not one of the 9 actions above falls back
  to `search`. There is no LLM reply path in the shipped app.

### 1.2 Find / open files (Files page + chat)

- Files page (`src/renderer/components/FilesPage.tsx`): search box
  (`Find a file by name or by what is inside it...`), Search button, Rebuild index
  button. Results are Explorer-style rows (`FileRow.tsx`): file-type icon (see
  §1.5), name in bold, folder path underneath, snippet (when present), size and
  date on the right (`1.5 MB`, `12 Nov 2026` — `formatBytes` / `formatDate`,
  `src/renderer/utils/fileTypes.ts`), Open button per row. Empty result → empty
  state with a Rebuild-index action.
- `openFile(path)` (`src/main/services/actions.ts`): Windows →
  `cmd.exe /c start "" <path>` (OS default app); non-Windows → `xdg-open <path>`.
  Returns `{ok, message}`; failure message `I could not open that file: <err>`.
- `openFolder(path)`: Electron `shell.openPath(path)` (Explorer on Windows).
- Folder-name search uses `rankFolders()` (§5.3): exact name = 100; all query words
  across name+parent = 70; per-word name hit = 25; per-word parent hit = 10 (capped
  20); full-path contains phrase = +15; keep only scores within 20 of the best,
  max 8 folders; tie-break shorter path, then name. Stopwords removed:
  `folder, folders, directory, directories, the, a, an, in, open, find, show, go, to, that, this, related, please`.
- **File watching: none.** There is no `chokidar`, no `fs.watch`, no background
  watcher anywhere in `src/`. New/changed files appear only after a manual
  **Rebuild index**. The Flutter port must not promise live watching unless it
  adds it as a new feature.

### 1.3 Duplicates (Duplicates page + chat)

See §2 for the full rules. UI (`DuplicatesPage.tsx`, `DuplicateGroupCard.tsx`):
- Page loads `findDuplicates()` on open; Refresh button `Find duplicates`; loading
  skeletons; empty state `No duplicates found`.
- One card per group: header `<keeper name> — <sizeText>, <N> copies, <wasted> wasted`
  (`wasted = size × (copies − 1)`, formatted `formatBytes`); keeper row first with a
  `keep` badge and **no checkbox**; each extra copy has a `Delete` checkbox.
- `Delete selected copies` (destructive variant) → `AlertDialog`:
  `Delete these copies?` / `These copies go to the Recycle Bin. The first copy is kept. Are you sure?`
  → `deleteDuplicates(selectedPaths)` → result line
  `Deleted <N> copie(s) to the Recycle Bin.` + per-error lines + `Log: <logPath>`,
  then the group list is re-fetched.
- `Merge into one folder` → dialog with a Target folder text field, note
  `All <N> copies move into this folder. The folder is created if it does not exist. Check the path before confirming.`
  (Note: the note text is inaccurate — the code keeps the first copy in place, §2.)
  Default target is hardcoded `C:\Users\dhanu\Downloads\Merged` — **a bug to fix in
  Flutter: derive it from the user's home/Downloads folder, never hardcode a username.**
- After delete/merge the list refreshes via a fresh `findDuplicates()` call.

### 1.4 Organize Downloads (Organize page + chat)

See §2 for the full rules. UI (`OrganizePage.tsx`, `ChatMessage.tsx` `RANGES`):
- Range buttons: Today `{kind:'today'}`, Yesterday `{kind:'yesterday'}`,
  Last 3 days `{kind:'lastDays',days:3}`, Last 7 days `{kind:'lastDays',days:7}`,
  All `{kind:'all'}`. Chat text parsing: `all|everything|every file` → all;
  `yesterday` → yesterday; `last|past <N> days?` → lastDays N (min 1);
  `this week|last week` → last 7 days; `today` → today.
- `planOrganize(range)` → kind `organize-plan` (or plain message
  `Nothing to organize in Downloads for <label> — no files added then.`).
  Plan shown as a table (File / Move from / Move to / Folder); in chat only the
  first 20 moves are shown + `and <N> more`. Buttons: `Yes, move them` (primary)
  and `Cancel` (ghost; in chat, cancelling replaces the plan with
  `Organize cancelled. Nothing was moved.`).
- `applyOrganize(plan)` → kind `organize-done`, text
  `Moved <N> file(s). Every move is in <logPath>.` (or `Nothing was moved.`),
  plus an `errors` list. After applying, the Organize page clears the plan and
  shows the result text.
- Organize touches **Downloads only** (see §2). It never touches other folders.

### 1.5 Screens, navigation, command palette

`src/renderer/pages.ts` — 7 pages, in this order:
`command` Command Center, `files` Files, `duplicates` Duplicates, `organize` Organize,
`system` System, `memory` Memory, `settings` Settings.
Shell (`App.tsx`, Astryx `AppShell`): top nav with heading `DJ`, capability badge
(§3.4) + status dot, `Search` (ghost) button that opens the palette; side nav with
the 7 pages + a Status section showing `<N> files indexed`, search mode
(`meaning search` / `keyword search only` / `loading status…`), embedder label
(`embedder ready (bundled model)` / `(downloaded model)` / `embedder loading` /
`embedder not available` / `embedder not started`); footer capability line with the
plain-language layer message (§3.4). A stale-index banner appears when
`indexStale` is true: `The search index was built with an older format — Rebuild index to use meaning search.`
An update banner appears when update status is `ready` (message text from §1.9).
A tray note appears once (see §1.8).

- **Command palette (Ctrl+K / Cmd+K anywhere):** 12 commands —
  `Go to <each of the 7 pages>` (group Pages) + 5 actions (group Actions):
  `Rebuild index` (keywords index, rebuild, scan), `Open folders settings`
  (folders, settings, add folder), `Find duplicates` (duplicates, copies, extra),
  `Organize Downloads` (organize, downloads, move), `Refresh status`
  (refresh, status, reload). Empty text: `No matching page or action`;
  bootstrap text: `Type to search pages and actions`. `Find duplicates` and
  `Organize Downloads` navigate to those pages; the others run immediately.
- **StatusCards** (Command Center top, `StatusCards.tsx`) — 3 cards, all numbers
  from `DjStatus`: (1) Capability — badge + `capability.message`; (2) Index —
  `<filesIndexed> files in <foldersIndexed> folders`, search-mode badge,
  embedder label, Rebuild index + Folders buttons; (3) Model — `Local model running: <name>`
  or `Local model not running`, `Cloud key works` / `Cloud key expired or invalid` /
  `Cloud key set, not checked yet` / `No cloud key set`, note
  `DJ works with no model and no key. A model or key only adds better answers.`
- **Files page:** §1.2. **Duplicates page:** §1.3. **Organize page:** §1.4.
- **System page** (`SystemPage.tsx`): Refresh button; shows CPU %, CPU cores, RAM
  used/total + %, uptime (`2d 3h 14m` / `5h 12m` / `32m` / `45s` via
  `formatUptime()`), platform string — each row labelled with its source
  (`Source: …`). Loading skeletons; error card with `Try again`. Disk usage is
  **not shown** (no reliable built-in call — DJ never invents a number; CPU is
  `null` → UI says so instead of inventing a value).
- **Memory page** (`MemoryPage.tsx`): read-only. Tabs `Long-term` (MEMORY.md) /
  `Daily notes` (last 14 daily files, newest first). Search box filters lines
  case-insensitively (`filterMemoryLines()`); empty file → empty state, never
  placeholder text.
- **Settings page** (`SettingsPage.tsx`): 4 cards — (1) Folders DJ searches
  (enabled folder paths listed, Folders + Rebuild index buttons); (2) Capability
  (`<badge label>: <capability.message>`, `Embedder: <state> (<source> model)` when
  ready, Refresh status button); (3) Always running — switch
  `Start DJ when Windows starts` (description: `DJ opens on its own when you sign in, and keeps running in the tray when you close its window.`)
  + note when a tray exists: `To fully quit DJ, right-click the tray icon and choose Quit DJ.`;
  (4) About DJ — `DJ runs on this laptop only. Files never leave the laptop, and DJ works with no model and no API key.`
- **Folders dialog** (`FoldersDialog.tsx`): shown on first run (no index yet,
  title `Set up DJ`, required dialog, button `Save and build index`) and from the
  Folders button (title `Folders`, button `Save`). Each folder row: enable/disable
  checkbox (label = full path) + Remove button. `Add folder` → native folder picker
  (`pickFolder()`); duplicates are ignored. Save is disabled when 0 folders are
  enabled. Saving stores the config **and immediately starts a full index rebuild**
  (toast: `Folders saved. Rebuilding index.`).
- **File-type icons** (`fileTypes.ts`, `FileRow.tsx`): kinds `word, pdf, image, video,
  audio, folder, sheet, archive, code, text, file`. Word: `.doc/.docx`; PDF: `.pdf`;
  image: `.png/.jpg/.jpeg/.gif/.webp/.bmp/.svg/.ico`; video: `.mp4/.mov/.avi/.mkv/.webm/.wmv`;
  audio: `.mp3/.wav/.ogg/.flac/.m4a`; sheet: `.xls/.xlsx/.ods`; archive:
  `.zip/.rar/.7z/.tar/.gz`; code: `.js/.ts/.jsx/.tsx/.py/.java/.c/.cpp/.h/.html/.css/.json/.xml/.sql/.sh`;
  text: `.txt/.md/.csv/.log/.rtf`; anything else / no extension → `file`.
  Case-insensitive. `formatBytes`: `<1024` → `N B`; else 1 decimal KB/MB, 2 decimals GB.
  `formatDate`: ISO → `12 Nov 2026` (`en-GB`, day 2-digit, month short, year numeric);
  empty/invalid → `''`.
- **Index progress UI:** during a build a progress bar shows `IndexProgress.message`
  with percent (`done/total`, indeterminate while `total == 0`); progress events are
  throttled to at most one per 150 ms (`PROGRESS_MIN_MS`), final `done` always sent.
  After a build the chat posts:
  `Index built: <files> files, <folders> folders, <embedded> with meaning search, <keywordOnly> keyword only[, <new> new][, <reused> reused][, <removed> removed][, <skipped> skipped][, <errors> errors]. Took <seconds>s.`

### 1.6 Summarize a file

- Extractive only — `summarizeText()` (`src/main/services/summarizeService.ts`).
  **No model, no LLM, no generative summary.** The UI must keep saying so.
- Rules: collapse whitespace; empty text → `That file looks empty, so there is nothing to summarize.`
  (`usedFirstLines: true`). Keywords = words (>2 chars) from the file name without
  extension. Split into sentences on `(?<=[.!?])\s+`. If ≤ 5 sentences, return them
  all joined (`usedFirstLines: true`). Otherwise score each sentence: < 4 words →
  −100; > 60 words → −50; else `min(wordCount, 30)` + 5 per keyword contained;
  keep score > 0, take top 5 by score, re-order by original position, render as
  `• <sentence>` lines joined with `\n` (`usedFirstLines: false`).
- Reply note (verbatim, `chatService.ts`):
  `Summary from the file itself (first lines) — DJ has no AI model, so it picks the key sentences out of the file.`
  or `Summary picked from the file itself — DJ has no AI model, so it picks the key sentences out of the file.`
  (first variant when `usedFirstLines` is true).
- Source text is `getFileText(path)` = `readText()` capped at 8,000 chars (§5.2).

### 1.7 Open an installed app by name

`openApp()` (`src/main/services/appLauncher.ts`). `KNOWN_APPS` in the brain
(`brainService.ts`) that route here: `notepad, chrome, calculator, paint, word,
excel, powerpoint, edge, vs code, code, spotify, whatsapp, explorer, file explorer,
settings, cmd, terminal, clock`.
Lookup table `APP_PATHS` (Windows exe names / absolute paths):
notepad `notepad.exe`; chrome `chrome.exe`, `C:\Program Files\Google\Chrome\Application\chrome.exe`,
`C:\Program Files (x86)\Google\Chrome\Application\chrome.exe`; calculator `calc.exe`;
paint `mspaint.exe`; word `winword.exe`; excel `excel.exe`; powerpoint `powerpnt.exe`;
edge `msedge.exe`, `C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe`;
`vs code`/`code` `code.exe`; spotify `spotify.exe`; whatsapp `whatsapp.exe`;
explorer/`file explorer` `explorer.exe`; cmd `cmd.exe`; terminal `wt.exe`, `cmd.exe`;
clock `clock.exe`. Special case: `settings` → `cmd.exe /c start ms-settings:`.
Unknown name → fallback candidate `<name>.exe`; resolution: absolute path must
exist as a file, otherwise search `PATH` (+ `PATHEXT` on Windows). Not found →
`I could not find an app called '<name>' on this laptop. Try the full name, like 'Google Chrome', or open it yourself once and tell me.`
Found → `spawn(exe, [], {detached: true, stdio: 'ignore'})`, `child.unref()`,
`Opened <name>.` (lowercased key). `isWindows()` = `process.platform === 'win32'`;
DJ targets Windows only. In Flutter this needs a Windows platform channel /
process launch — see §7. **Clock / reminder / alarm are explicitly not in v3**
(`appLauncher.ts` header: "Clock, reminder and alarm live on the user's mobile for
now — those come later, not in v3") — do not port them as working features.

### 1.8 Tray + auto-start (v5.6)

`src/main/services/tray.ts`, wired in `main.ts`:
- **Tray:** icon candidates in order: packaged `resources/tray-icon.ico`, else
  repo `assets/icon.ico`. If no icon file exists, **no tray is created** and closing
  the window quits (old behaviour). Tray tooltip: `DJ - your files, found`.
  Context menu (exactly 2 items, in order): `Open DJ`, `Quit DJ`. Plain click on
  the icon = Open. `decideCloseAction({hasTray, isQuitting})`: `isQuitting` → quit;
  else tray present → **hide**; no tray → quit. `isQuitting` is set only by the
  tray `Quit DJ` menu (or a real quit). `showWindow()`: restore if minimized,
  then show + focus. `window-all-closed` quits only when `tray === null`.
  On `before-quit` the tray icon is destroyed.
- **First-hide note (once):** first time the window hides into the tray,
  `notifyTrayHiddenOnce()` sets `config.trayNoteSeen = true` (persisted in
  `dj_config.json`) and sends `dj:tray-hidden` to the renderer; the UI then shows,
  on next open, a dismissible banner: `DJ keeps running in the tray. Right-click the tray icon to open or quit.`
  It must never appear again after dismissal / after the flag is set.
- **Start at login:** `resolveStartAtLogin(saved, isPackaged)` = `saved ?? isPackaged`
  (default ON in the packaged app, OFF in dev). Applied only when packaged:
  `app.setLoginItemSettings({openAtLogin: enabled})` (Electron uses the installed
  exe path for NSIS). The Settings toggle calls `setStartAtLogin(enabled)`, which
  persists the choice in config **and** applies it in the OS in the same call, and
  returns the value now in effect. In dev the choice is saved but not registered
  with the OS. `DjStatus` carries the effective `startAtLogin` and `hasTray`.

### 1.9 Updates

`src/main/services/updateService.ts` (electron-updater, GitHub Releases):
- Enabled only when `isPackaged && !isWindowsStore`
  (`shouldEnableAutoUpdate()`). In dev the service stays idle; in the Microsoft
  Store build it stays idle too — **the Store updates the app itself; the two
  routes must never fight.**
- Check on startup after a 15 s delay (`CHECK_DELAY_MS = 15_000`), then once a day
  (`CHECK_INTERVAL_MS = 24 h`). `autoDownload = true`, `autoInstallOnAppQuit = true`.
  **Never restarts the app by itself; installs when DJ quits.** The UI only shows
  the state; the `ready` banner is the only update UI.
- States (`UpdateStatus`, `src/shared/types.ts`): `idle, checking, available,
  downloading, ready, up-to-date, error`. Messages (verbatim,
  `updateStatusMessage()`): checking `Checking for updates…`; available
  `DJ <v> is available — downloading it now.`; downloading `Downloading the DJ update…`;
  ready `DJ <v> is ready — restart DJ to install it.`; up-to-date `DJ is up to date.`;
  error `Could not check for updates — DJ keeps working as-is.` (with a detail:
  `Could not check for updates (<msg>) — DJ keeps working as-is.`).
  Download-progress ticks map to `downloading` (no percentage is shown).
- Publisher: `build.publish = {provider: 'github', owner: 'dhanunjayss0306', repo: 'dj-laptop-agent'}`.
  The first GitHub Release must exist before any of this works; data in `userData`
  is untouched by updates. In Flutter this needs a replacement updater (no
  electron-updater) — see §7.

### 1.10 Settings / folders (config)

`AppConfig` (`src/shared/types.ts`): `{folders: FolderEntry[] /* {path, enabled} */,
localModel?: {kind: 'ollama'|'lmstudio', model?: string},
cloud?: {provider: 'openai'|'openrouter'|'anthropic', apiKey?: string},
startAtLogin?: boolean, trayNoteSeen?: boolean}`.
Stored as pretty JSON (`JSON.stringify(config, null, 2)`) in `dj_config.json`.
`ConfigRepository.load()`: corrupt JSON or missing file → defaults (never crash).
`save()` creates the directory first.
- **Default folders** (`defaultFolders()`, `config.ts`) — exactly 5, all enabled:
  `<home>/Downloads`, Desktop (see below), `<home>/Documents`, `<home>/Pictures`,
  `<home>/Antigravity` if it exists, else `<home>` itself. **DJ never indexes the
  whole C: drive** (comment in `config.ts`: Windows system files would slow the
  index and fill results with junk).
- Desktop resolution (`findDesktop(home)`): `<home>/OneDrive/Desktop` first if it
  is a directory, else `<home>/Desktop` (the user's Desktop is the OneDrive one).
- `enabledFolders(config)`: enabled entries whose path is an existing directory;
  missing folders are silently skipped.
- **Important gap — no UI for `localModel` / `cloud`:** no renderer screen edits
  `localModel` or `cloud.apiKey`; the fields exist in the type and in
  `dj_config.json` only, and are read by the capability probes (§3). The Flutter
  port must decide with the user whether to add a Settings UI for them (recommended:
  a small, clearly-labelled optional section — local-model kind/model, cloud
  provider + key field stored locally only, never logged, never sent except to the
  chosen provider). Do not invent a key-entry flow that the Electron app never had
  without flagging it as new.

---

## 2. File-operation rules (the law of DJ — port exactly)

**The governing rule (README + every service header): DJ never edits what is inside
a file. It only finds, opens, deletes (to Recycle Bin), merges (moves), and organizes
(moves).** The only writes DJ ever makes to user files are: *move* (rename) and
*send to Recycle Bin*. There is no edit, no rename-in-place of content, no
in-place modification, no "fix this file" operation anywhere in `src/`.

### 2.1 Allowed operations

| Operation | What it does | Where |
|---|---|---|
| Find / search | Read-only. Reads file text for the index; never writes into the file. | `IndexService` |
| Open file | Opens with the OS default app (`cmd /c start`, §1.2). | `actions.openFile` |
| Open folder | Opens in Explorer. | `actions.openFolder` |
| Open app | Spawns an exe, detached. | `appLauncher.openApp` |
| Summarize | Reads text, returns sentences. Read-only. | `summarizeService` |
| Organize | **Move only** (rename). Never delete, never overwrite. | `OrganizeService` |
| Delete duplicates | **Recycle Bin only** (see §2.3). | `DuplicateService.deleteToRecycleBin` |
| Merge duplicates | **Move only** (see §2.4). Never delete, never overwrite. | `DuplicateService.merge` |

### 2.2 "Merge" — exact definition

`DuplicateService.merge(paths, targetFolder)`:
- Requires `paths.length >= 2`; otherwise error
  `Nothing to merge — a group needs at least two copies.` and nothing moves.
- `paths[0]` is the copy that **stays where it is** (the keeper = first element of
  the group, which the UI sorts alphabetically, §2.5). Every other path
  (`paths.slice(1)`) is **moved** (filesystem rename) into `targetFolder`.
- `targetFolder` is created if it does not exist (`mkdirSync(..., {recursive: true})`).
- Destination is `freePath(targetFolder, basename)` — **never overwrites**: if the
  name exists, append `-1`, `-2`, … before the extension (`stem-1.ext`).
- A file that is gone before the move → per-file error `<name>: gone before I could move it.`
  and the rest still move. Any other failure → per-file error `<name>: <err>`.
- Returns `{moved: string[] /* destination paths */, errors: string[]}`.
- Merge does **not** combine file contents, does not deduplicate inside a file, does
  not delete anything. "Merge" = "collect the extra copies into one folder".
- The merge dialog's note (`All <N> copies move into this folder`) contradicts the
  code (first copy stays). Port the **code behaviour**, and fix the note to say the
  first copy stays.

### 2.3 Trash vs permanent delete

- **There is no permanent delete anywhere in DJ.** `deleteToRecycleBin()` is the
  only delete path. It uses the npm `trash` package (v9), loaded lazily via
  `require('trash')`; if the package is missing it returns the error
  `The trash package is not installed, so I cannot delete safely. Run: npm install — then try again.`
  and deletes nothing.
- Pre-check per path: not existing / not a file → error `<name>: already gone.`
  and that path is skipped. Existing paths are trashed in **one** `trash(existing)`
  call; a failure there → single error `Could not move files to the Recycle Bin: <err>`
  and nothing is reported as deleted.
- Every successful deletion is appended to the log CSV
  `<Downloads>/_Organizer_Log.csv` (header `Name,OldPath,NewPath,Date` when the file
  is created; rows `"name","path","Recycle Bin (deleted)","YYYY-MM-DD"`, CSV-quoted
  with `"` doubled). A log-write failure is reported as an error, not silently ignored.
- Returns `{deleted: string[], errors: string[], logPath: string}`.
- **UI rule:** the UI must confirm first (AlertDialog, §1.3) and the keeper
  (first copy) must never be offered for deletion — the checkbox exists only on
  copies `files[1..]`.
- **Judge gate (partially dead — read carefully):** `ChatService.deleteDuplicates()` /
  `mergeDuplicates()` call `judgeAction()` (§3.5) and refuse when `blocked` is
  non-empty (e.g. 0 targets → `no target named — nothing would be touched, so nothing runs`).
  **But the IPC handlers in `ipcControllers.ts` do NOT call those ChatService
  methods** — `dj:delete-duplicates` calls `duplicates.deleteToRecycleBin()` directly
  and `dj:merge-duplicates` calls `duplicates.merge()` directly, so the judge does
  **not** run on the path the UI actually uses. In Flutter, port the *effective*
  behaviour (UI confirm dialog is the real gate) and, if the judge is ported (§3.5),
  wire it into the service method the UI calls — do not reproduce the dead wiring.

### 2.4 Organize — exact rules

`OrganizeService` (`src/main/services/organizeService.ts`), rules copied from the
user's own script `Organize-Downloads.ps1`:
- **Scope:** only files **directly in** `~/Downloads` (top level, `readdirSync`
  non-recursive). Subfolders are untouched. Date filter uses each file's **mtime**
  (last-modified date, `YYYY-MM-DD`): `today` = today only; `yesterday` = yesterday
  only; `lastDays N` = **today + the N days before it** (N+1 calendar days, so a file
  from exactly N days ago is still included); `all` = no date filter (`null` set).
- **Never moved:** `organize-downloads.ps1`, `_organizer_log.csv`, `downloads-preview.csv`
  (`ORGANIZER_SKIP`, case-insensitive). A file gone/unreadable at plan or apply time
  is skipped with a per-file error.
- **Destination — first match wins, keyword folders before type folders:**
  1. Name ends with `.env` (case-insensitive) → `_Private-DoNotShare`.
  2. Keyword folders, in this exact order (substring match on the lowercased file name):
     - `_Private-DoNotShare`: `credentials`, `recovery-codes`, `recovery codes`, `atlas-credentials`
     - `Hackathons/SAPSS-Vishwakarma`: `sapss`, `saps`, `vishwakarma`, `smart public`, `public sanitation`, `sanitation`, `toilet`, `pulse box`, `pulse_box`
     - `Hackathons/SasyaSakhi-AgriTech`: `sasyasakhi`, `soilsaathi`, `soil`, `smart farm`, `smart farming`, `agritech`, `agri`, `crop`, `farmer`, `saiya`, `sasya`
     - `Hackathons/Virun-Travel`: `virun`, `yatra`, `yatrasetu`, `travel titan`, `traveltitans`, `localmate`, `tourism`, `tourist`, `samartha`, `nataraj`, `hatra`
     - `Hackathons/GlobalTap`: `globaltap`, `global tap`
     - `Hackathons/Persona`: `persona`
     - `Hackathons/Quantum`: `quantum`
     - `Hackathons/HackerRank`: `hackerrank`, `ghost data`, `hacerrank`
     - `Hackathons/VRGym`: `vrgym`, `vr gym`, `vr-gym`
     - `Projects/Chaiya`: `chaiya`
     - `Projects/Health`: `patient`, `health concern`
     - `College`: `ada`, `assignment`, `employee dataset`, `startup summit`, `idea presentation`, `coa`, `oopj`, `os-lab`, `os lab`, `probability`, `book list`, `exam prep`, `multiplexer`, `demultiplexer`, `experiment`, `lab manual`
  3. Special image rules: `whatsapp image` → `Images/WhatsApp`; `chatgpt image` → `Images/ChatGPT`; `screenshot` → `Images`.
  4. Type folders by extension: Programs `.exe/.msi`; Movies `.mp4/.mkv/.avi/.mov/.webm`;
     Music `.mp3/.wav/.flac/.aac`; Images `.jpg/.jpeg/.png/.gif/.webp/.heic/.svg/.jfif/.bmp`;
     Documents `.pdf/.docx/.doc/.txt/.md`; Spreadsheets `.xlsx/.xls/.csv`;
     Presentations `.pptx/.ppt`; Code `.py/.js/.ts/.jsx/.tsx/.html/.css/.json/.ipynb/.dxf`;
     Archives `.zip/.rar/.7z/.tar/.gz`.
  5. Anything else → `_Review`.
  Destination folder is shown with the OS separator (`folderParts.join(path.sep)`,
  e.g. `Hackathons/Virun-Travel`).
- **Plan then confirm:** `plan(downloadsDir, range)` moves nothing; it returns
  `OrganizeMove[]` (`{name, old, new, folder}`) sorted alphabetically by file name,
  with `new` already collision-free via `freePath()`. `apply(plan, downloadsDir)`
  re-checks existence, re-checks the free path **at move time** (never overwrite),
  creates the destination directory, renames, and logs every move to
  `<Downloads>/_Organizer_Log.csv` (same header/format as §2.3, rows
  `"name","old","new","YYYY-MM-DD"`). Returns `{moved, errors, logPath}`.
- `freePath(destFolder, name)`: if free, use it; else `stem-1.ext`, `stem-2.ext`, …

### 2.5 Duplicates — exact rules

`DuplicateService.find(folders)` (`src/main/services/duplicateService.ts`):
- Walk each enabled folder recursively, skipping: `SKIP_DIRS` (§5.1), any directory
  starting with `.`, symlinked directories, files starting with `.`, and
  `ORGANIZER_SKIP` files. Yields to the event loop every 10 folders / 200 entries
  so the UI never freezes.
- **Group by size first** (only sizes with 2+ files are hashed), **then by SHA-256
  of contents** (`sha256File()`: streaming, 1 MB chunks, hex digest). Two files with
  the same size but different contents are **not** duplicates. `fileId()` for chunk
  ids is different: SHA-1 of the full path, first 16 hex chars.
- **Skipped:** empty files (size 0) and files over **500 MB** (`MAX_DUP_MB = 500`).
- Group: `id = "<size>-<first file path>"`, `size`, `sizeText` (`humanSize()`:
  `2450 → 2.4 KB`, units B/KB/MB/GB, 1 decimal), `wasted = size × (files.length − 1)`,
  `files[]` = `{path, name, folder, mtime}` with `mtime` = ISO date `YYYY-MM-DD`
  (blank on stat failure). Files within a group are sorted **alphabetically,
  case-insensitive**; the first is the keeper. Groups sorted by `wasted` descending
  (biggest waste first).

### 2.6 What is forbidden (must be enforced in Flutter, not just documented)

1. Never edit file contents. No write-into-file API may exist in the service layer.
2. Never permanently delete. The only delete is Recycle Bin (Windows) / Trash.
3. Never overwrite on move/merge/organize — always `freePath()` (`-1`, `-2`, …).
4. Never move a file outside Downloads in Organize (except a merge target the user
   explicitly typed/confirmed).
5. Never open a file the user did not pick (skill playbook `skills/find-file.md`:
   `Never open a file the user did not pick. Never guess a path.`). Chat `open`
   opens only the top search result *for an explicit open request* — that is the
   one exception, and it must stay visible in the reply (`Opened <name>.` + results).
6. Never act on files outside the enabled folders — see `WorkspaceGuard` (§3.5):
   resolve to an absolute path inside an allowed root; `..` escapes and absolute
   paths outside every root are denied (`null` = do not touch). **Note:** this guard
   is defined in `v53/security.ts` but is not wired into the IPC/chat paths in the
   Electron app; the Flutter port should wire it in for real (open/delete/merge/
   organize targets must pass through it).
7. Destructive actions always need a human confirm — even when a judge scores 5/5
   (`judge.ts`); nothing auto-deletes, nothing auto-sends. "Sending is always manual
   — DJ drafts, you press send" (there is no send feature in the app; do not add one
   without a new decision).
8. Never invent a number (System page), never silently drop a file (index reports
   skipped/unreadable files by name, first 20), never silently empty a summary.

---

## 3. The 3-layer fallback (Cloud → Local → Core)

Source: `src/main/v53/capability.ts`, `src/main/v53/primitives.ts`, `src/main/main.ts`
(probes), `src/shared/types.ts` (`CapabilityLayer`, `CapabilityStatus`,
`LocalModelHealth`, `CloudHealth`), `src/main/v53/README.md`. **Numbering note:**
the README and `primitives.ts` number the layers Cloud=2, Local=1, Core=0; the
type is `'cloud' | 'local' | 'core'`. The task's "Cloud → Local → Core" is the
fallback order (best first, Core last).

### 3.1 Layer 0 — Core (always on)

- **Needs:** nothing. No model, no key, no network, no server.
- **Does:** everything the shipped app actually does — file find/open (keyword +
  meaning search via the tiny embedder, §5), open folders, open apps, summarize
  (extractive), organize with preview, duplicates find/delete/merge, list recent
  files, system info, memory files (read-only UI + heartbeat appends), help.
  `CoreProvider.chat()` (`v53/security.ts`) answers any free-form prompt with the
  fixed string: `Core only: I can find, open, organise, and summarise your files with rules — no model is running, so I cannot chat freely.`
  Its `health()` always returns `true`.
- **Guarantee (stated in code, must hold in Flutter):** "Core file work never
  depends on Layer 1 or 2, so it can never break this way." A dead local model or
  an expired cloud key must never break search/open/delete/organize.
- Defaults (`defaultPrimitives()`): `intelligence.model = ''` (none),
  `fallbackChain = ['cloud', 'local', 'core']`, `engine.kind = 'none'`
  (`'none'` is a real, valid engine = Core only), `agents.defaultAgent = 'simple'`,
  `maxToolSteps = 8`, `toolsMemory.memoryBackend = 'markdown-files'`,
  `learning.enabled = true`, `learning.maxTraces = 200`.

### 3.2 Layer 1 — Local (optional)

- **Needs:** a local model server already running on the laptop, started by the
  user — **DJ never starts, downloads, or bundles it.** `AppConfig.localModel`
  is `{kind: 'ollama' | 'lmstudio', model?: string}`. The example / preferred model
  named in code is **`qwen3.5:9b`** (`primitives.ts` comment, `types.ts`
  `LocalModelHealth.name` example `Ollama (qwen3.5:9b)`). That is a ~9-billion-
  parameter model class; the code states no download size, no RAM requirement and
  no bundled copy — do not invent one. (User context outside this spec: qwen3.5:9b
  and qwen2.5-coder:7b run on his laptop via Ollama; gemma3:12b failed and stays
  skipped. That is user history, not a code fact — the port must not hard-require
  any of it.)
- **Probe** (`checkLocalModel()`, `main.ts`): try in order
  `http://127.0.0.1:11434/api/tags` (Ollama), then `http://127.0.0.1:1234/v1/models`
  (LM Studio), each with a **1.5 s** timeout (`AbortSignal.timeout(1500)`).
  First server that answers HTTP OK with a `models[0]` returns
  `{available: true, name: "<Server> (<first model name/id>)"}`; OK with no models →
  `{available: true, name: "<Server>"}`. Both silent → `{available: false, reason:
  'local model not running'}`. A dead server is "not running", never a hang.
- **What it does in the shipped app:** nothing beyond the probe + status display.
  No code calls Ollama/LM Studio's chat/generate endpoint. The *design* (voice.ts
  `routeTask()`, agentLoop `ThinkFn`) is: when a model is up, quick classify/command
  tasks route to a `fast-judge` and full answers to a `chat-model`; the agent loop's
  "think" step may be the model instead of Core rules. That is a design stub, not
  shipped behaviour — port the routing *shape* if the Flutter build adds real local
  chat, otherwise port probe + status only and say so.

### 3.3 Layer 2 — Cloud (optional)

- **Needs:** a provider key the user pastes into `dj_config.json` (`cloud:
  {provider: 'openai' | 'openrouter' | 'anthropic', apiKey?: string}`). The key
  lives on the laptop only, is never logged, and is sent only to the provider the
  user picked. **No UI exists to enter it** (§1.10).
- **Probe** (`checkCloudKey()`, `main.ts`): no key → `{configured: false, valid: null,
  reason: 'no cloud key set'}`. Otherwise `GET <base>/models` with a **2 s** timeout:
  bases `openai https://api.openai.com/v1`, `openrouter https://openrouter.ai/api/v1`,
  `anthropic https://api.anthropic.com/v1`; headers `Authorization: Bearer <key>`
  except Anthropic (`x-api-key: <key>` + `anthropic-version: 2023-06-01`).
  HTTP 200 → `{configured: true, valid: true}`. **401/403 → `{configured: true,
  valid: false, statusCode, reason: 'cloud key expired or invalid (<code>)'}` —
  that is the signal to fall back, never to retry** (`isAuthError()` =
  status 401 or 403). Any other status / network failure →
  `{configured: true, valid: null, statusCode?, reason: 'cloud could not be checked'}`.
- **What it does in the shipped app:** nothing beyond the probe + status display.
  No code calls any provider's chat endpoint. Same stub warning as §3.2.

### 3.4 How the fallback decides

`CapabilityManager.resolve(force = false)` (`capability.ts`):
- **Cache:** 30 s (`cacheMs = 30_000`). `resolve()` returns the cached status inside
  the window; `getCapability()` forces a fresh check (`resolve(true)`). `getStatus()`
  calls `resolve()` (cached). A probe that throws → that layer is unavailable, never
  a crash (`safeCheckLocal` / `safeCheckCloud`).
- **Decision (in order):**
  1. `cloud.configured && cloud.valid === true` → layer `cloud`,
     message `Cloud` (+ ` (local model also available)` if local is up).
  2. Else `local.available` → layer `local`, message
     `Local model (<name>)` (+ ` — <cloud reason>` if a cloud key is configured but invalid).
  3. Else layer `core`, message `Core only: <reasons joined with ', '>`, where reasons are
     `cloud.reason` when a key is configured but invalid (`cloud key expired or invalid (401)`),
     or `cloud could not be checked` when configured but uncheckable, plus
     `local.reason` (`local model not running`).
- Result: `CapabilityStatus {layer, local, cloud, message, checkedAt (ISO)}`.
- **Heartbeat** (`main.ts`): every 30 minutes `capability.resolve(true)`; **only a
  layer change is noted** — recorded in the in-memory `TraceStore` (`route:
  'capability-check'`, `fallback: '<old> -> <new>'`) and appended to today's daily
  note (`Layer changed: <old> -> <new> (<message>)`). It never acts on files.
- **UI badge** (`capabilityBadge()`, `pages.ts`): no status → `Checking` (neutral);
  `cloud` → `Cloud` (success, green dot); `local` → `Local model` (success);
  core + `cloud.valid === false` → `Core only` (warning, yellow dot,
  `Cloud key expired or invalid, running on Core`); core otherwise → `Core only`
  (neutral, `Core layer, no model or key`). The footer line always shows
  `capability.message` in plain words, e.g. `Core only: cloud key expired, local model not running`.

### 3.5 The v5.3 supporting machinery (port the shape; note what is unwired)

All in `src/main/v53/`, ideas re-implemented from other projects (see README — no
other project's code is copied). Status in the Electron app:

| Module | What it is | Wired into the shipped app? |
|---|---|---|
| `capability.ts` | `CapabilityManager`, `isAuthError` | **Yes** — `main.ts` + `getStatus`/`getCapability`. |
| `primitives.ts` | `DjPrimitives` (intelligence/engine/agents/toolsMemory/learning), `TraceStore` (bounded ring, max 200, `id: tr-<n>`, `TraceRecord {id, at, route, tools[], ms, layer, fallback?}`, `telemetry()` = count/avgMs/toolCalls/fallbacks/byLayer) | **Partially** — `defaultPrimitives()` + `TraceStore` created in `main.ts`; traces are recorded **only** by the heartbeat on layer change. No per-chat-interaction tracing is wired in. |
| `judge.ts` | `judgeAction()` — Read → Judge → Draft → Check → Fill; score `S = 0.7·G + 0.3·E` out of 5; `JudgeTarget = reply\|delete\|merge\|send\|organize\|open`; blocked when: empty text (`nothing to act on`), destructive with 0 targets (`no target named — nothing would be touched, so nothing runs`); warnings when: destructive and targetCount > 50 (`this would touch <N> files — check the list first`), goal text not in plan (`the plan does not clearly match the goal you stated`), destructive (`destructive: needs your confirm before anything runs`), kind `send` (`sending is always manual — DJ drafts, you press send`); `needsConfirm = destructive \|\| kind==='send' \|\| blocked.length>0`. A destructive action always needs a human confirm, even at score 5. | **Barely** — called only by `ChatService.deleteDuplicates()` / `mergeDuplicates()`, which the IPC layer bypasses (§2.3). Port the function and wire it into the real delete/merge path. |
| `agentLoop.ts` | `AgentLoop` (think → call tool → observe, repeat, **max 8 steps**, never infinite; `coreThink` default: call a tool whose name appears in the task, then answer from the observation; never call the same tool twice for one task — in practice the loop returns after the first observation), `MemoryFiles` (MEMORY.md + `memory/YYYY-MM-DD.md`; `saveFact()` appends `- <date> <text>`, `appendDaily()` appends `- <HH:MM:SS> <text>`), `loadSkillPlaybooks(dir)` (reads `*.md`, title = first non-empty line minus `#`), `Heartbeat` (setInterval, `unref`, `tick()` for tests). | **Partially** — `MemoryFiles` + `Heartbeat` used in `main.ts` (heartbeat only). `AgentLoop` / `coreThink` / `loadSkillPlaybooks` are **not called** from `main.ts` or any IPC handler. |
| `security.ts` | `WorkspaceGuard` (deny-all; `resolve()` returns absolute path inside a root or `null`), `ModelProvider` interface (`id, kind: core\|local\|cloud, chat(prompt), health()`), `CoreProvider` (fixed reply, §3.1), `ProviderRegistry` (Core always registered; `defaultProvider()` = Core). | **Not wired** into any IPC/chat path. Port `WorkspaceGuard` and wire it in (§2.6.6). |
| `skills.ts` | `SkillRegistry` (keyword routing: highest keyword-hit count wins; `run()` executes actions in order, **max 3 attempts per action = first try + 2 retries**, then stop at `failedAt`; success claimed only when every action returned `ok` **with evidence**), `LayeredMemory` (temporary = in-memory map; persistent = `<dataDir>/memory-persistent.json`; daily = today's note file). | **Not wired** into `main.ts`/IPC. Port as the skill-playbook shape if skills are kept. |
| `router.ts` | `classifyRequest()` — pure keyword classifier, confidence < 0.5 → ask. Image words (`image, photo, picture, screenshot, jpg, jpeg, png, gif, webp`) → `image` 0.9, route `['read-image','describe','search']`; `isVoice` → `voice` 0.9, route `['transcribe','classify','answer','speak']`; system words (`cpu, ram, memory usage, disk, battery, system info, how much space, temperature`) → `system` 0.85, route `['classify','system-info']`; file words (`open, find, search, summar, organiz, duplicat, list, file, folder, download`) → `file` 0.8, route `['classify','search','open']`; else `text` 0.6, route `['classify','answer']`. A step runs only when the previous step succeeded. | **Not wired** into `ChatService` (which uses `BrainService` instead). Do not present the router as the live classifier. |
| `voice.ts` | See §4. | **Not wired** into any UI or IPC. |

Skill playbooks on disk: `~/workspace/dj-app/skills/find-file.md`,
`skills/organize-downloads.md` (short numbered playbooks, §2.6.5 rules). `loadSkillPlaybooks()`
is never called by `main.ts`, so the shipped app does not load them at runtime.

---

## 4. Voice assistant flow

**Honest status first: there is no working voice assistant in the shipped app.**
No microphone capture, no speech-to-text, no text-to-speech, no wake-word listener,
no voice button, and no voice IPC channel exist in `src/`. A grep for
`voice|speech|microphone|Web Speech` across `src/` hits only `v53/voice.ts`,
`v53/router.ts` (the `voice` route) and the v5.3 README. The Flutter port must
not claim voice works today; implement it as a **new feature** on the design below,
or ship v1 without voice and say so.

### 4.1 What exists today (design + pure functions, `src/main/v53/voice.ts`)

Design taken from the isair/jarvis idea (no isair code):
- **Name-addressed listening:** DJ answers only when addressed by name.
  `parseAddressed(text)`: regex `^(?:hey|ok|okay|hello|hi)?\s*dj\b[\s,:\-]*` (case-insensitive,
  leading filler allowed). Match → `{addressed: true, query: <text with the name stripped>, wakeWord: <'hey'|'ok'|'okay'|'hello'|'hi'|'dj'>}`;
  no match → `{addressed: false, query: <raw>, wakeWord: null}`.
  Examples: `DJ, find my notes` → addressed, `find my notes`; `hey DJ open chrome` → addressed.
- **Rolling transcript:** `RollingTranscript` — keeps the last **20 segments** /
  **30 seconds** (`maxSegments = 20`, `windowMs = 30_000`), in memory only, nothing
  on disk; old segments drop off (`prune()`). `recent()` joins segments with spaces;
  `findAddressed()` scans newest-first for an addressed segment.
- **Two-model routing:** `routeTask({kind, modelUp})` — `modelUp == false` → always
  `'core-rules'`; else `classify|command` → `'fast-judge'`, `answer|dictate` →
  `'chat-model'`. The router never assumes a model exists.
- **Diary + knowledge-graph memory:** `diaryLine({at, kind, text})` =
  `- <at> [<kind>] <text>` — short dated lines in local plain-text memory files,
  never in the cloud. (Same storage as `MemoryFiles`, §3.5.)
- **Dictation:** "where the browser supports it, Web Speech API transcribes locally
  into any text box. No new binary, no bundled speech model." — a design note only;
  no Web Speech code is wired into the renderer.

### 4.2 What the Flutter port must build for voice (new work, not a port)

1. Mic capture + on-device or platform STT (e.g. `speech_to_text` on Windows, or a
   platform channel to Windows Speech / Whisper — decision needed; note that
   Electron's Web Speech API does not exist in Flutter).
2. Feed transcripts into `RollingTranscript` (20 segments / 30 s, memory only),
   run `parseAddressed()` on each segment, ignore everything not addressed to DJ.
3. Route the addressed query through the existing `BrainService`/`ChatService`
   (Core) — or `routeTask()` when a local/cloud model is up — and render the same
   `ChatResponse` the text chat renders.
4. Speak the reply: `serviceGraphFor('voice')` = `['transcribe','classify','answer','speak']`.
   TTS via a platform channel / `flutter_tts`; no TTS exists today, so voice
   output is also new.
5. Privacy: transcripts stay in memory (rolling window only); diary lines go to
   local memory files only, never to any cloud. The wake word is `DJ` (with optional
   `hey|ok|okay|hello|hi` prefix).

---

## 5. Data model

### 5.1 What is indexed

- **Folders:** only the enabled entries of `AppConfig.folders` (§1.10). Defaults:
  Downloads, Desktop (OneDrive first), Documents, Pictures, Antigravity-or-home.
  Never the whole drive.
- **File types indexed** (`READABLE_EXTS`, `indexService.ts`) — exactly 16 extensions:
  `.txt, .md, .py, .js, .ts, .jsx, .tsx, .html, .css, .json, .csv, .log, .pdf, .docx, .pptx, .xlsx`.
  Everything else is invisible to search (but **is** visible to duplicate-finding,
  which walks all files regardless of extension, §2.5, and to Organize, which works
  by file name/extension in Downloads).
- **Walk rules** (`IndexService.iterFileEntries` / `walkDir`):
  - Skip directories (`SKIP_DIRS`, lowercased name match): `appdata, .git,
    node_modules, __pycache__, .venv, venv, .cache, .antigravity, dj_data,
    $recycle.bin, system volume information`; any directory starting with `.`;
    directory symlinks/junctions (never followed).
  - Skip files starting with `.`; skip non-readable extensions; skip files
    **> 20 MB** (`MAX_FILE_MB = 20`); skip non-files (sockets, fifos).
  - Dedupe by `realpathSync()` — the same file reached by two paths is indexed once.
  - One bad folder (permission error, OneDrive hiccup, broken link) is skipped with
    a console note; the build continues. Progress reported per folder, then every
    200 files found; yields to the event loop every 200 entries (`WALK_YIELD_EVERY`)
    and every 100 ms during the read phase (`YIELD_EVERY_MS`).
- **Folders are indexed too** (`iterFolders()`): every directory under the enabled
  folders (same skip rules), **including the roots themselves**, recorded as
  `IndexedFolder {path, name (basename), parent (dirname)}` — this is how
  "open the frontend folder" / "open AuPro" works. `listFolders()` returns them
  sorted by name.
- **Incremental rebuild (v5.5):** a file whose `size` + `mtimeMs` match the saved
  keyword index is **not re-read or re-embedded** — its keyword entry and vectors
  are reused. Only new/changed files are read and embedded; files that are gone
  drop out (`removed` count). Exception: when the stored chunk version is not
  `CHUNK_VERSION` (PDFs became page-aware in v5.5), PDF rows are re-embedded once.
  Counts returned: `IndexCounts {files, folders, chunks, embedded, keywordOnly,
  skipped, errors, seconds, vectorOk, reused?, new?, removed?, skippedNames? (first 20)}`.

### 5.2 How file text is read

`readFileContent()` (`src/main/services/fileReader.ts`) — read-only, lazy library
loading (a broken PDF/DOCX library must never stop the app starting). Status is
honest, never silently empty: `ReadStatus = 'ok' | 'no-text' | 'encrypted' | 'unreadable'`.

| Extension | How | Notes / limits |
|---|---|---|
| `.txt` `.md` `.py` `.js` `.ts` `.jsx` `.tsx` `.html` `.css` `.json` `.csv` `.log` | Plain text, UTF-8 with latin1 fallback | Binary sniff first: a NUL byte in the first 512 bytes → `unreadable`. |
| `.pdf` | `pdf-parse` (v1.1.1), custom `pagerender` that appends a form feed `\f` after every page (pdf-parse's own default has no page marks) | Text capped at **200,000 chars** (`PDF_TEXT_LIMIT`). Pages but zero extractable text → `no-text` (scanned-image PDF — note: `<name> has no readable text inside — scanned image, needs OCR.`). Error mentioning encrypt/password → `encrypted` (note: `<name> is locked (encrypted) — open it with its password first.`). Other parse failure → `unreadable`. Page count reported when available. |
| `.docx` | `mammoth` raw text | Empty → `no-text`. |
| `.pptx` | `jszip` + XML: `<a:t>` text runs from `ppt/slides/slide<N>.xml`, in slide order | Best-effort only: no slide notes, no formatting. Empty → `no-text`. |
| `.xlsx` | `jszip` + XML: shared-strings table + cell values row by row (`xl/worksheets/sheet<N>.xml`); `s` = shared string, `inlineStr` = inline, else number/boolean/date or a formula's **stored result** | No formulas beyond stored results, no charts. Empty → `no-text`. |
| `.doc` `.ppt` `.xls` (old binary Office) | **Not supported** — skipped plainly | Needs a heavy binary parser DJ does not ship. |
| Anything else in `READABLE_EXTS` | Falls through to the plain-text path | — |

- **Per-file read timeout:** 15 s (`READ_TIMEOUT_MS`). A slow/corrupt file is
  counted in `errors`, its name added to `skippedNames` (first 20), logged, and the
  build continues. (Note: for pdf-parse the parse may keep running in the background;
  the build just stops waiting.)
- **Keyword text kept per file:** first **12,000 chars** (`KEYWORD_TEXT_LIMIT`).
  Files with `no-text`/`encrypted` status are still indexed **by name** with their
  honest `note` — a scanned PDF is still findable by name.

### 5.3 How the vector / keyword index works

**Keyword index** (`KeywordIndexRepository`, `keyword_index.json`):
`{version: 1, files: IndexedFile[], folders: IndexedFolder[]}`.
`IndexedFile {path, name, folder (dirname), text (first 12,000 chars),
size?, mtimeMs?, note?}`. Corrupt file → start empty. Saved **before** embedding
(phase 1), so keyword search works immediately even if the model takes minutes.

**Vector store** (`VectorStore` + `VectorRepository`):
- In-memory brute-force cosine search — no server, no native module, no DB process.
  Vectors are L2-normalized on store, so cosine = dot product. At DJ's scale
  (tens of thousands of chunks) this is a few ms per query. `search(queryVector, topN)`:
  zero query vector → no matches; dot over `min(query.length, stored.length)` dims
  (a shorter query must not read past the array and produce NaN); scores rounded to
  3 decimals.
- On-disk format: `vectors.bin` (flat float32 rows, 768 per row, same order as the
  meta array) + `vectors_meta.json`
  (`{embedFormat, embedModel, dim: 768, chunkVersion?, vectors: VectorMeta[]}`) +
  `index_meta.json` (`{embedFormat, embedModel, chunkVersion}`).
  `VectorMeta {id, path, name, folder, chunk, text}`.
  `EMBED_FORMAT_VERSION = 2` (format 1 = raw text, no prefixes; format 2 = nomic
  task prefixes). `storedFormat() !== 2` with vectors present → `indexStale = true`.
  Load rejects the store when `dim !== 768` or the float count ≠ `vectors.length × 768`.
- **Chunking** (`utils/text.ts`): `CHUNK_WORDS = 400`, `OVERLAP_WORDS = 50`
  (a sentence straddling a boundary is not lost). `CHUNK_VERSION = 1`.
  `chunkText()`: split on whitespace, 400-word windows stepping by 350.
  `chunkPdfText()`: split on `\f` (page breaks), chunk each page separately,
  prefix each chunk `[page N] `; pages with no text skipped; no `\f` → plain `chunkText()`.
  Chunk id: `<fileId>-<chunkIndex>`, `fileId = sha1(full path).slice(0, 16)`.
- **Search merge** (`IndexService.search(query, topN = 8)`):
  1. Keyword search first (instant). **A file whose NAME matches wins outright** —
     return keyword results only, without waiting on the model (`nameMatches()`:
     any query word > 2 chars, or the whole query, contained in the name). This
     matters for scanned PDFs, which have no vectors.
  2. Else, if `vectorOk && embedder.isReady()`: embed the query, vector-search
     `topN × 2` hits, dedupe by path to `topN` files (snippet = first 160 chars of
     the chunk text), then **meaning hits first, keyword-only extras after, no
     duplicates** (`mergeResults()`). `lastMeaning = 'ready'`.
  3. Else (model not ready): return keyword results at once with a plain note
     attached to every result (`withMeaningNote()`; a file's own note is kept and
     the meaning note appended): loading → `Meaning search is still loading — these are keyword matches for now.`;
     unavailable / not-indexed → `Meaning search is unavailable right now — these are keyword matches.`
     A search never waits the 5-minute build timeout or the 8-second query timeout
     when the model is not ready. `lastMeaning` is `loading | unavailable | not-indexed`.
- **Keyword scoring** (`keywordSearch()`): split query on non-word chars, keep words
  > 2 chars (else the whole lowercased query as one term). Per file: name contains
  word → **+10**; text occurrences → **+1 each, capped at 20 per word**.
  Sort by score descending, take `topN`. Snippet (`snippet()`): 160 chars around the
  first query word found (40 chars before it), whitespace-collapsed, `...` if cut;
  no word found → first 160 chars; no text → the file's `note` (or `''`).
- **Embedding batches:** new chunks embedded in batches of **5** (`EMBED_BATCH`),
  yielding between batches. If a batch fails / returns the wrong count, those
  chunks count as `keywordOnly` (not an error that aborts the build). When the
  embedder is down, reused rows are still kept — the build never wipes good vectors
  because the model was off. If the final row set is empty, the store is cleared
  and `vectorOk = false`. Stored model string: `'Xenova/nomic-embed-text-v1.5'`
  (passed to `store.replace()`).
- **Embedder timeouts** (`EmbedderClient`): build flushes wait up to **300 s**
  (`EMBED_TIMEOUT_MS`) — the first load compiles a ~137 MB model in WASM and is slow;
  a search waits at most **8 s** (`QUERY_TIMEOUT_MS`). A timed-out *search* does not
  poison the embedder state (the model may still be loading); only a build flush
  that waited the full window marks it `unavailable`. No window to send to →
  `unavailable` immediately.

### 5.4 The embedder model (nomic-embed-text)

- **Model:** `nomic-ai/nomic-embed-text-v1.5` (`EMBED_MODEL_ID`, `src/shared/modelSource.ts`).
  Official nomic-ai repo; transformers.js 3.8 understands its `nomic_bert` config natively.
- **Size (measured in this repo):** the bundled copy is **~132 MB total** —
  `resources/models/nomic-ai/nomic-embed-text-v1.5/onnx/model_quantized.onnx` is
  **131 MB** (the q8-quantized ONNX file), plus `tokenizer.json` 695 KB,
  `config.json` 2.5 KB, `tokenizer_config.json` 1.2 KB, `special_tokens_map.json`
  695 B. Comments in the code round this to "~150 MB" / "about 150 MB" and
  "137 MB" for the model file — use **131 MB on disk, ~150 MB as the user-facing
  figure** already used in the README.
- **Dimensions:** **768** (`VECTOR_DIM`, `EMBED_DIM`). Mean-pooled, L2-normalized,
  one 768-number vector per text (`pipeline('feature-extraction', …, {dtype: 'q8'})`,
  `extractor(texts, {pooling: 'mean', normalize: true})`).
- **Task prefixes (mandatory, silent-failure trap):** the model was trained with
  prefixes — main adds `search_document: ` in front of indexed chunks and
  `search_query: ` in front of a search query (`DOC_PREFIX` / `QUERY_PREFIX`,
  `embedderClient.ts`). Prefixes are sent to the model only; stored texts are
  unchanged. **Without them retrieval gets worse with no error raised.**
  Format version 2 exists precisely because format 1 stored vectors without prefixes.
- **Where it runs (Electron):** in the **renderer** (Chromium) via
  `@huggingface/transformers` v3.7 with the **WebAssembly ONNX backend** — no native
  module, no server, no LM Studio. ONNX Runtime Web WASM files ship inside the app
  (`public/ort/` → `dist/renderer/ort/`), **not from a CDN** (transformers.js
  defaults `wasmPaths` to jsdelivr, which needs internet — the code overrides it to
  a relative `./ort/` URL). Main asks the renderer over IPC (`dj:embed-request` /
  `dj:embed-response`, `EmbedRequest {id, texts, forQuery}`, `EmbedResponse {id,
  vectors: number[][] | null, error?}`); the renderer answers with vectors.
  It loads **once** (`loadPromise` guard); after that it stays in memory.
- **Bundled vs downloaded** (`EmbedderSource`): `bundled` = shipped inside the
  installed app under `resources/models/` (electron-builder `extraResources`:
  `resources/models → models`, `assets/icon.ico → tray-icon.ico`); main serves it on
  the private `dj-model://` scheme (`MODEL_PROTOCOL`, `MODEL_BASE_URL =
  'dj-model://models/'`, `modelUrlForFile(modelId, file)`) with path-traversal
  protection (`resolveModelFile()` — resolved path must stay under the models dir)
  and a real `Content-Length` header (without it transformers.js cannot pre-allocate
  and first load is far slower). Missing file → 404 → transformers.js falls back to
  downloading the same repo from the **Hugging Face hub** once (`env.allowLocalModels
  = true`, `env.localModelPath = MODEL_BASE_URL`, `env.useBrowserCache = !bundled` —
  the Cache API rejects non-http(s) keys, so caching is off for bundled loads).
  The renderer detects the bundle by fetching `config.json` through the scheme.
  `downloaded` = fetched from the hub (browser cache keeps it afterwards).
  `none` = no model loaded (or it failed). If the model cannot load at all (no
  bundle, no internet) the embedder reports `unavailable` and DJ falls back to
  keyword search.
- **Embedder states** (`EmbedderState`): `not-started` (until the first embed is
  attempted) → `loading` → `ready` / `unavailable`. `DjStatus` carries
  `embedderState` + `embedderSource`; `vectorOk` is true only when usable vectors exist.
- **Flutter implication:** there is no transformers.js in Dart. The port must pick
  one: (a) `onnxruntime` Dart package loading the same `model_quantized.onnx` +
  a Dart/ONNX tokenizer for nomic-embed-text-v1.5 (tokenizer files are in the bundle
  already); (b) a small native/FFI helper; or (c) an HTTP call to a local
  embedding server (changes the "no server" guarantee — needs a user decision).
  Whichever is chosen, it must reproduce: 768-dim, mean pooling, L2 normalization,
  q8 model, the two prefixes, and the `bundled → downloaded → unavailable` fallback.
  **Vectors stored by Electron (format 2, 768-dim, prefix-trained) must remain
  usable by the Flutter build** — do not change the embedding contract or every
  user's existing index becomes stale.

### 5.5 On-disk files (all under `<userData>/dj_data/` unless noted)

| File | Writer | Contents |
|---|---|---|
| `dj_config.json` | `ConfigRepository` | `AppConfig` (pretty JSON). Corrupt → defaults. |
| `keyword_index.json` | `KeywordIndexRepository` | `{version: 1, files: IndexedFile[], folders: IndexedFolder[]}` |
| `vectors.bin` | `VectorRepository` | Flat float32, 768 per row, same order as `vectors_meta.json` |
| `vectors_meta.json` | `VectorRepository` | `{embedFormat: 2, embedModel, dim: 768, chunkVersion, vectors: VectorMeta[]}` |
| `index_meta.json` | `VectorRepository` | `{embedFormat, embedModel, chunkVersion}` (used by `storedFormat()` / `storedChunkVersion()`) |
| `MEMORY.md` | `MemoryFiles.saveFact()` | Long-term facts, one `- YYYY-MM-DD <text>` line each |
| `memory/YYYY-MM-DD.md` | `MemoryFiles.appendDaily()` / heartbeat | Daily notes, `- HH:MM:SS <text>` lines; Memory page reads newest 14 |
| `memory-persistent.json` | `LayeredMemory` (skills.ts) | Persistent key→value facts (unwired in the shipped app) |
| `<Downloads>/_Organizer_Log.csv` | `OrganizeService` / `DuplicateService` | `Name,OldPath,NewPath,Date` + one row per move/delete (NOT in the data dir) |
| (bundled, read-only) `resources/models/nomic-ai/nomic-embed-text-v1.5/*` | installer | The embedder model (§5.4) |

- `TraceRecord`s are **in memory only** (never written to disk, never sent anywhere).
  The rolling transcript is in memory only. The chat history is in memory only
  (not persisted — a restart starts with just the welcome message).
- **Privacy rule (README / PRIVACY.md):** nothing leaves the laptop — no account,
  no API key, no cloud, no paid service — except the two explicit, user-configured
  exceptions: a local-model probe to `127.0.0.1`, and a cloud-key validity check
  (`GET /v1/models`) to the single provider the user picked. The embedder's
  hub-download fallback is the third network touch, and only when the bundle is missing.

### 5.6 Other data types (verbatim from `src/shared/types.ts`)

- `SearchResult {path, name, folder, snippet, score, size?, mtime? (ISO), note?}`.
- `DuplicateGroup {id, size, sizeText, wasted, files: DuplicateFile[]}`;
  `DuplicateFile {path, name, folder, mtime}`.
- `OrganizeMove {name, old, new, folder}`; `OrganizeRange = {kind:'today'} |
  {kind:'yesterday'} | {kind:'lastDays', days: number} | {kind:'all'}`.
- `ChatAction = search|open|openFolder|summarize|organize|duplicates|list|openApp|help`
  (each `{action, query: string}`).
- `ChatResponse` kinds: `message {text}`; `search {text, results}`; `opened {text, results}`;
  `summary {text, fileName, summary, note}`; `organize-plan {text, label, range, plan}`;
  `organize-done {text, moved, errors, logPath}`; `duplicates {text, groups}`;
  `duplicates-deleted {text, deleted, errors}`; `duplicates-merged {text, moved, errors}`;
  `ask-range {text}`; `help {text}`; `folders {text, folders: IndexedFolder[]}`.
  (Note: `duplicates-deleted` / `duplicates-merged` are defined in the type but the
  shipped chat/UI paths return plain messages + the `deleteDuplicates`/`mergeDuplicates`
  result objects instead — port the type, but match the actual reply shapes above.)
- `DjStatus {filesIndexed, foldersIndexed, vectorOk, embedderState, embedderSource,
  hasIndex, indexStale, config, capability, startAtLogin, hasTray}`.
- `SystemStats {cpuPercent: number|null, cpuCores, totalMemBytes, freeMemBytes,
  uptimeSeconds, platform, checkedAt}` — CPU from two `os.cpus()` samples 500 ms apart,
  `null` when the samples are identical/backwards; disk deliberately omitted.
- `IndexProgress {stage: 'scan'|'read'|'done', done, total (0 while scanning),
  message}`.
- `MemoryContent {memoryMd: string, daily: MemoryDay[]}`; `MemoryDay {date, text}`.
- `UpdateState {status, message, version?}`.

---

## 6. IPC surface — every operation the UI calls

Electron channel names (`IPC` const, `src/shared/ipc.ts`) and the typed `DjApi`
(`window.dj` in `src/preload/preload.ts`). **In Flutter there is no IPC** — port this
as the Dart service API with the same method names, parameters and return types.
`invoke` = request/response; `send/on` = pushed events (Flutter: `Stream`s).

### 6.1 Request/response (invoke)

| # | Channel | `DjApi` method | Args | Returns | Handler (main) |
|---|---|---|---|---|---|
| 1 | `dj:get-status` | `getStatus()` | — | `DjStatus` | `ipcControllers`: loads config, `indexer.status()`, `getTrayInfo()`, `capability.resolve()` (30 s cached). |
| 2 | `dj:get-capability` | `getCapability()` | — | `CapabilityStatus` | `capability.resolve(true)` — forces a fresh probe, bypasses the cache. |
| 3 | `dj:get-config` | `getConfig()` | — | `AppConfig` | `configRepo.load()`. |
| 4 | `dj:save-config` | `saveConfig(config)` | `AppConfig` | `AppConfig` (re-loaded) | `configRepo.save(config)` then `load()`. No validation in the handler. |
| 5 | `dj:build-index` | `buildIndex()` | — | `IndexCounts` | `indexer.build(enabledFolders())`. Long-running; progress via §6.2. |
| 6 | `dj:search` | `search(query, topN?)` | `string` | `SearchResult[]` | `indexer.search(query, 8)` — **topN is hardcoded to 8 in the handler; the preload also drops the caller's `topN`** (`search: (query) => invoke(IPC.search, query)`). Port: accept `topN` with default 8, and actually honour it. |
| 7 | `dj:send` | `send(text)` | `string` | `ChatResponse` | `chat.handle(text)` (§1.1). Always returns a response; never throws to the UI in normal use. |
| 8 | `dj:plan-organize` | `planOrganize(range)` | `OrganizeRange` | `ChatResponse` (`organize-plan` or `message`) | `chat.planOrganize(range)` (§2.4). |
| 9 | `dj:apply-organize` | `applyOrganize(plan)` | `OrganizeMove[]` (sent as `{plan}`) | `ChatResponse` (`organize-done`) | `chat.applyOrganize(payload.plan)`. |
| 10 | `dj:find-duplicates` | `findDuplicates()` | — | `DuplicateGroup[]` | `duplicates.find(enabledFolders())`. Long-running; no progress events. |
| 11 | `dj:delete-duplicates` | `deleteDuplicates(paths)` | `string[]` (sent as `{paths}`) | `{deleted, errors, logPath}` | **Direct** `duplicates.deleteToRecycleBin(paths, <Downloads>)` — bypasses `ChatService`/judge (§2.3). |
| 12 | `dj:merge-duplicates` | `mergeDuplicates(paths, targetFolder)` | `string[]`, `string` (sent as `{paths, targetFolder}`) | `{moved, errors}` | **Direct** `duplicates.merge(paths, targetFolder)` — bypasses `ChatService`/judge (§2.3). |
| 13 | `dj:open-app` | `openApp(name)` | `string` | `{ok, message}` | `appLauncher.openApp(name)` (§1.7). |
| 14 | `dj:open-file` | `openFile(path)` | `string` | `{ok, message}` | `actions.openFile(path)` (§1.2). |
| 15 | `dj:pick-folder` | `pickFolder()` | — | `string \| null` (null = cancelled / no window) | `dialog.showOpenDialog(win, {properties: ['openDirectory']})`, first path or null. |
| 16 | `dj:open-folder` | `openFolder(path)` | `string` | `{ok, message}` | `actions.openFolder(path)` (Explorer). |
| 17 | `dj:get-system-stats` | `getSystemStats()` | — | `SystemStats` | `readSystemStats()` (§1.5, §5.6). |
| 18 | `dj:get-memory` | `getMemory()` | — | `MemoryContent` | `readMemoryContent(dataDir)` — MEMORY.md + newest 14 daily files, read-only. |
| 19 | `dj:set-start-at-login` | `setStartAtLogin(enabled)` | `boolean` | `boolean` (value now in effect) | Persists to config **and** applies in the OS (packaged only); returns `enabled`. |

### 6.2 Pushed events (main → renderer; Flutter: Streams)

| # | Channel | Direction | Payload | Notes |
|---|---|---|---|---|
| 20 | `dj:index-progress` | main → UI | `IndexProgress` | Sent during `buildIndex()`; throttled to 1 per 150 ms; `done` always sent. UI subscribes once at startup. |
| 21 | `dj:embed-request` | main → renderer embedder | `EmbedRequest {id, texts, forQuery}` | Main asks the renderer to embed; renderer must answer on #22. In Flutter this becomes an internal call to the embedder service — keep the `id` correlation and the two timeouts (§5.3). |
| 22 | `dj:embed-response` | renderer → main | `EmbedResponse {id, vectors \| null, error?}` | Resolves the pending promise in `EmbedderClient`; unknown `id` ignored; error/null → state `unavailable`. |
| 23 | `dj:embedder-state` | renderer → main | `string` (`ready\|loading\|unavailable`) | Renderer reports its embedder state; main stores it for `DjStatus`. |
| 24 | `dj:embedder-source` | renderer → main | `string` (`bundled\|downloaded\|none`) | Renderer reports where its model came from. |
| 25 | `dj:update-status` | main → UI | `UpdateState` | Sent by `UpdateService` on every updater event (§1.9). UI subscribes once at startup. |
| 26 | `dj:tray-hidden` | main → UI | (no payload) | Sent once, the first time the window hides into the tray (§1.8). UI shows the tray note. |

Total: **26 channels** (19 invoke + 7 event directions; `embed-request`/`embed-response`
are the two halves of one embed round-trip). The preload exposes exactly one object,
`window.dj`, with `contextIsolation: true, nodeIntegration: false, sandbox: false` —
the renderer never touches the filesystem or the embedder directly. In Flutter this
security boundary becomes code structure (UI layer must not import `dart:io` file
operations directly; all file work goes through the service layer), not a process boundary.

### 6.3 Callers in the UI (so nothing is missed)

- `App.tsx`: `getStatus, onIndexProgress, onUpdateStatus, onTrayHidden, buildIndex,
  saveConfig, send, planOrganize, applyOrganize, openFile, openFolder, setStartAtLogin`.
- `FilesPage.tsx`: `search`. `DuplicatesPage.tsx`: `findDuplicates`.
  `DuplicateGroupCard.tsx`: `findDuplicates, deleteDuplicates, mergeDuplicates`.
- `OrganizePage.tsx`: `planOrganize, applyOrganize`. `FoldersDialog.tsx`: `pickFolder`.
- `SystemPage.tsx`: `getSystemStats`. `MemoryPage.tsx`: `getMemory`.
- `SettingsPage.tsx` / `StatusCards.tsx`: read-only (via `status`/`config` props;
  `getEmbedderState/Source` from the local embedder module). `main.tsx`:
  `onEmbedRequest(handleEmbedRequest)`, `reportEmbedderState()` at startup.

---

## 7. Windows-only / Electron-only — needs a different approach in Flutter

| Electron / Windows thing | Where | Flutter approach (Windows-first) |
|---|---|---|
| `BrowserWindow` (880×720, no menu, `did-fail-load` fallback) | `main.ts` | Flutter desktop window (`window_manager` or `bitsdojo_window` for size/title; or plain Flutter window). No webview, no load-fallback logic. Single window. |
| Preload + `contextBridge` + `ipcMain/ipcRenderer` | `preload.ts`, `ipcControllers.ts` | Delete. Direct Dart service calls (§6). Keep the method list as the API. |
| `app.getPath('userData')` | `utils/paths.ts` | `path_provider` `getApplicationSupportDirectory()` (Windows: `%APPDATA%\<app>\`). Append `dj_data` and keep the §5.5 file names byte-identical so existing users keep their index/config. |
| `app.setLoginItemSettings({openAtLogin})` | `main.ts`, `tray.ts` | No Flutter equivalent built-in. Use `launch_at_startup` package (writes the Windows Run registry key) or a platform channel to the Registry. Must reproduce: default ON when installed, OFF in dev; toggle persists + applies in one call. |
| System tray (`new Tray(icon)`, context menu, click, tooltip) | `tray.ts` | `tray_manager` (or `system_tray`) + `window_manager` for hide-on-close. Must reproduce: no icon file → no tray → close quits; 2-item menu (Open DJ / Quit DJ); click = open; `isQuitting` flag so only Quit really quits; destroy icon on quit. Flutter tray plugins differ in click/menu behaviour per version — verify against §1.8, do not assume. |
| `shell.openPath()` (Explorer) | `actions.ts` | `open_file` / `url_launcher` (`launchUrl` with a directory Uri is unreliable on Windows — prefer a platform channel running `explorer.exe <path>` or `open_filex`). Verify on a real Windows machine. |
| `cmd.exe /c start "" <file>` (open file) | `actions.ts` | Platform channel / `process_run`: `cmd /c start "" <path>` on Windows. Quote paths with spaces correctly — the Electron code passes the path as a single argv element to `cmd.exe`; reproduce that, do not build a shell string by concatenation. |
| Spawning exes by name / PATH + PATHEXT lookup | `appLauncher.ts` | `dart:io Process.start(exe, [], mode: ProcessStartMode.detached)` + manual PATH/PATHEXT search (Dart has no `which`). Keep the §1.7 table, the `settings` → `ms-settings:` special case, and the exact not-found message. |
| Recycle Bin delete (`trash` npm package) | `duplicateService.ts` | No Dart equivalent of the `trash` package. Needs a platform channel: Windows `SHFileOperation` / `IFileOperation` with `FOF_ALLOWUNDO`, or a small native helper. **Do not implement delete as `File.delete()`** — that is permanent and violates §2.3. This is a must-have before shipping delete. |
| Native folder picker (`dialog.showOpenDialog`) | `ipcControllers.ts` | `file_picker` `getDirectoryPath()` (returns null on cancel — same contract as `pickFolder()`). |
| `dj-model://` private scheme + `protocol.handle` | `modelProtocol.ts` | Delete. Bundle the model as a Flutter asset / app-support file and load from disk (§5.4). No custom scheme, no fetch-based model loading. |
| `@huggingface/transformers` + WASM ONNX in Chromium | `renderer/embedder.ts` | **Hardest part — see §5.4.** Options: `onnxruntime` Dart package + Dart tokenizer, or FFI/native helper, or a local embedding server (user decision; changes the no-server guarantee). Must reproduce 768-dim, mean pooling, L2 norm, q8 model, both prefixes, bundled→downloaded→unavailable fallback. |
| `electron-updater` (GitHub Releases, `autoInstallOnAppQuit`) | `updateService.ts` | No Flutter equivalent. Options: `updater` / `shorebird_code_push` (different model — evaluate), or a hand-rolled check of the GitHub Releases API + download + install-on-quit via a platform channel / installer re-run. Must reproduce: packaged-only, never in the Store build, never auto-restart, install on quit, data dir untouched, the §1.9 states/messages. **Store builds must use the Store updater only.** |
| NSIS installer + MSIX / Store packaging (`electron-builder`) | `package.json` `build` | Flutter Windows build (`flutter build windows`) + MSIX via `msix` package for the Store; NSIS via `inno_setup` or equivalent for the direct installer. Reproduce: appId `com.dhanunjay.dj`, Store identity `DJservices.DJfiles`, shortcuts (desktop + Start menu, shortcut name `DJ`), bundled model as an extra resource, `tray-icon.ico`. |
| `process.windowsStore` detection | `main.ts`, `updateService.ts` | Detect Store vs direct install at runtime (e.g. package family / install location) and gate the self-updater off for Store builds. |
| OneDrive Desktop detection (`OneDrive/Desktop` first) | `utils/paths.ts` | `Platform.environment['USERPROFILE']` + check `<home>\OneDrive\Desktop` is a directory, else `<home>\Desktop`. |
| `os.cpus()` two-sample CPU % (500 ms apart) | `systemStats.ts` | No Dart `os` module. Use a platform channel (Windows PDH / `GetSystemTimes`) or a package such as `system_info2`. Must reproduce: null when unmeasurable, no disk usage (do not invent one — leave it out as Electron does). |
| No file watching / no global shortcuts | (absence) | Flutter must also not promise them in v1. In-app Ctrl+K palette must be reproduced with a Flutter `Shortcuts`/`CallbackShortcuts` (Ctrl+K; Cmd+K is macOS-only and out of scope for a Windows-first port). |
| Astryx design system (`@astryxdesign/core`, dark theme) | `App.tsx`, `main.tsx`, `index.css` | **Do not port.** See §8. |
| PDF/DOCX/PPTX/XLSX parsing (`pdf-parse`, `mammoth`, `jszip`) | `fileReader.ts` | Dart equivalents needed: PDF text extraction (e.g. `pdf_text` / Syncfusion / a platform helper — evaluate; must support per-page text so `[page N]` chunking works, and must distinguish scanned vs encrypted PDFs); DOCX = unzip + `word/document.xml` text runs (same technique as the JS code, portable to Dart with `archive`); PPTX/XLSX = unzip + XML pulls (port the regex/XML logic directly — it is format logic, not Electron logic). Old binary `.doc/.ppt/.xls` stay unsupported. Lazy-load / isolate the parsers so a broken parser never blocks startup; keep the 15 s per-file read timeout and the honest `ReadStatus`. |

**Isolates / responsiveness (port the intent, not the mechanism):** Electron keeps the
window responsive by yielding (`setImmediate`, 100 ms / 200-entry yields) and by
throttling progress to 1 per 150 ms. In Flutter the equivalents are: run index builds,
walks, hashing (SHA-256) and embedding batches in an **isolate** (or `compute()`),
stream progress no faster than ~150 ms, and never block the UI thread on a 500 MB hash
or a 137 MB model load. The duplicate scan already yields every 10 folders / 200 entries
in Electron — keep the same chunking in the isolate protocol.

---

## 8. What should NOT be ported

1. **The dark UI — do not port it.** DJ v5.4–v5.6 ships a dark theme
   (`src/renderer/index.css` header: "Dark chat theme, like the Muse chat";
   `main.tsx`: Astryx neutral theme in `mode="dark"`). Values: body `#1b1b1b`,
   sidebar `#141414`, DJ replies `#262626`, rows `#202020` / hover `#2e2e2e`,
   borders `#303030`, text `#f1f1f1`, muted `#b9b9b9` / `#9a9a9a`, user bubble
   `#0066cc` (deliberately darker than `#0071E3` because white on `#0071E3` is
   only ~4.5:1, on `#0066cc` ~5.6:1). **The Flutter build must use the white flat
   design law instead: white `#FFFFFF`, ink `#1D1D1F`, blue `#0071E3`, Inter;
   flat, no purple/gradients/glow, no decorative animated backgrounds, no pill
   buttons, no emoji icons, no fake reviews/metrics, functional motion only.**
   Keep the *layout* (top nav, side nav, 7 pages, chat left/right, Explorer-style
   rows, status cards, command palette) and the *copy* (verbatim strings in this
   spec); replace every colour, and re-check contrast on white (the `#0066cc`
   user-bubble note is a useful precedent: if white text on `#0071E3` is borderline,
   darken the bubble or use blue text on a light-blue surface — decide and record it).
   Also do not port the Astryx component library (`@astryxdesign/core`,
   `@astryxdesign/theme-neutral`) — rebuild the components as Flutter widgets.
2. **Dead / unwired v5.3 code — port the shape only where §3.5 says "port", do not
   present it as live behaviour:** `AgentLoop`/`coreThink`, `SkillRegistry`,
   `WorkspaceGuard` (port + wire in — the exception), `ProviderRegistry`/`CoreProvider`
   (port the interface if local/cloud chat is added later), `router.ts`
   `classifyRequest` (the live classifier is `BrainService`, not the router),
   `loadSkillPlaybooks` (never called; the two playbooks in `skills/` are reference
   docs, not runtime code), per-interaction `TraceStore` recording (only the
   heartbeat records traces today), `LayeredMemory` (never used by `main.ts`).
   Do not wire these in silently as new features; if the Flutter build activates one,
   flag it as new in the changelog.
3. **The voice assistant as a shipped feature** (§4) — the design exists, the
   feature does not. Ship without it, or build it as new work. Do not copy
   `voice.ts` and claim voice works.
4. **Real LLM chat (local or cloud)** (§3.2–3.3) — no chat endpoint is called in the
   shipped app. Port probes + status + the Core fallback message. Do not add an
   Ollama/OpenAI chat call as a "port" — it would be a new feature needing a key/model
   UX (§1.10) and a user decision.
5. **Clock / reminder / alarm** — explicitly deferred in `appLauncher.ts` ("live on
   the user's mobile for now — those come later, not in v3"). `clock.exe` launches
   the Windows Clock app via `openApp('clock')`; that is all. Do not build reminders.
6. **Image features** — the router has an `image` route (`read-image, describe,
   search`) and `classifyRequest` detects image words, but no image reading,
   description or image search exists anywhere in `src/`. Do not port it.
7. **Music player** — dropped by the user's choice (memory, 2026-11-12); nothing in
   `src/` implements one. Do not add it.
8. **Hardcoded personal paths** — `MERGE_TARGET_DEFAULT = 'C:\Users\dhanu\Downloads\Merged'`
   and the merge dialog placeholder `C:\Users\dhanu\Downloads\Merged` hardcode the
   username `dhanu`. Derive from the actual user's home in Flutter.
9. **The old C++ OOP syllabus / unrelated content** — not in this repo; ignore.
10. **Outdated claims in `package.json` / README** — the package description says
    "No LLM, no LM Studio, no cloud" and the README says "No Python, no LM Studio,
    no Ollama, no cloud API, no API key, no paid service." Those predate v5.3's
    optional layers. The accurate statement (port this): *Core works with no model
    and no key; Local (Ollama/LM Studio) and Cloud (OpenAI/OpenRouter/Anthropic key)
    are optional, probed, and fall back to Core.* Do not copy the old absolute wording.
11. **Electron packaging artefacts** — `dist/`, `release/`, `release-msix/`,
    `node_modules/`, `scripts/copy-ort.mjs`, the Vite/Electron build scripts.
    Port behaviour, not the build.
12. **Test-only seams that must not become user features** — injected `trashFn` in
    `deleteToRecycleBin`, injected probes in `CapabilityManager`, `ThinkFn` injection
    in `AgentLoop`. Keep the equivalent seams in Dart for tests, but do not surface
    them in the UI.

---

## 9. Suggested Flutter structure (for the builders — not a prescription)

```
lib/
  main.dart                 # window setup (880x720), service wiring, tray, heartbeat, updater
  models/                   # Dart equivalents of src/shared/types.ts (JSON-compatible field names)
  services/
    config_repository.dart  # dj_config.json, defaults, OneDrive Desktop
    index_service.dart      # walk, read, chunk, keyword+vector search, incremental rebuild
    vector_store.dart       # brute-force cosine, vectors.bin / vectors_meta.json
    keyword_index_repository.dart
    embedder_client.dart    # prefixes, 300 s / 8 s timeouts, states, batched embed (size 5)
    embedder.dart           # ONNX Runtime load + tokenize + mean-pool + L2 norm (see §5.4)
    file_reader.dart        # per-format text extraction + ReadStatus
    brain_service.dart      # rules routing (exact order in §1.1)
    chat_service.dart       # handle(), plan/apply organize, delete/merge (with judge wired in)
    duplicate_service.dart  # size -> SHA-256, Recycle Bin via platform channel
    organize_service.dart   # keyword/type folders, freePath, log CSV
    summarize_service.dart  # extractive, max 5 sentences
    app_launcher.dart       # exe table, PATH/PATHEXT, ms-settings:
    actions.dart            # openFile (cmd start) / openFolder (Explorer)
    system_stats.dart       # CPU two-sample, mem, uptime (platform channel)
    capability_manager.dart # 30 s cache, probes (1.5 s local / 2 s cloud), fallback messages
    update_service.dart     # GitHub Releases, packaged-only, install-on-quit
    tray_service.dart       # tray + start-at-login
    memory_files.dart       # MEMORY.md + daily notes, heartbeat 30 min
    judge.dart  capability.dart  primitives.dart  agent_loop.dart
    security.dart           # WorkspaceGuard — wire it in (see §2.6.6)
    skills.dart  router.dart  voice.dart   # port the shape; voice/router are stubs (§4, §3.5)
  ui/
    app_shell.dart  command_center_page.dart  files_page.dart
    duplicates_page.dart  organize_page.dart  system_page.dart
    memory_page.dart  settings_page.dart
    widgets/ file_row.dart  chat_message.dart  duplicate_group_card.dart
    folders_dialog.dart  status_cards.dart  command_palette.dart
  theme/ dj_theme.dart      # WHITE FLAT LAW: #FFFFFF / #1D1D1F / #0071E3 / Inter (§8.1)
```

**Acceptance checklist (minimum, before calling the port done):**
- [ ] All 7 pages render; Ctrl+K palette lists all 12 commands and each runs.
- [ ] First run with no index opens the folder setup and builds the index.
- [ ] Search finds by name (name match wins) and by meaning; keyword-only fallback
      shows the exact meaning notes; scanned/locked PDFs show their honest notes.
- [ ] All 9 chat actions work from the Command Center with the verbatim reply texts.
- [ ] Organize plans, then moves only on Yes, never overwrites, logs to
      `_Organizer_Log.csv`; keyword folders beat type folders; `_Review` fallback.
- [ ] Duplicates: same-size-different-content is not a duplicate; keeper never
      deletable; delete goes to the Recycle Bin (verify by restoring from the Bin);
      merge keeps the first copy and moves the rest with `-1` suffixes.
- [ ] No file content is ever edited (grep the service layer for write-into-file calls).
- [ ] Summaries say they are picked from the file itself, no AI.
- [ ] Capability badge shows Cloud / Local model / Core only with the exact messages;
      killing Ollama / expiring a key falls back to Core with the reason shown.
- [ ] Tray: close hides, Quit DJ quits, first-hide note appears exactly once;
      start-at-login toggle persists and applies.
- [ ] Existing `dj_data` (keyword_index.json, vectors.bin, vectors_meta.json,
      dj_config.json) from the Electron app loads and searches correctly.
- [ ] White flat theme throughout — no `#1b1b1b` / `#262626` / `#303030` surfaces remain.
- [ ] The 17 Electron test files' cases are reproduced as Dart tests (brain routing,
      organize destinations, duplicate grouping, chunking, vector search, judge scoring,
      capability fallback, pages/palette, system stats, tray decisions).

## 10. Source index (where every claim above came from)

- Types/IPC/model: `src/shared/types.ts`, `src/shared/ipc.ts`, `src/shared/modelSource.ts`
- Entry/tray/startup: `src/main/main.ts`, `src/main/services/tray.ts`
- Config/paths: `src/main/config.ts`, `src/main/utils/paths.ts`, `src/main/utils/hashing.ts`, `src/main/utils/text.ts`
- Index/search: `src/main/services/indexService.ts`, `src/main/services/vectorStore.ts`,
  `src/main/repositories/vectorRepository.ts`, `src/main/repositories/keywordIndexRepository.ts`,
  `src/main/services/fileReader.ts`, `src/main/services/embedderClient.ts`,
  `src/main/services/modelProtocol.ts`, `src/renderer/embedder.ts`
- Chat/brain: `src/main/services/brainService.ts`, `src/main/services/chatService.ts`,
  `src/main/services/summarizeService.ts`, `src/main/services/actions.ts`,
  `src/main/services/appLauncher.ts`
- Organize/duplicates: `src/main/services/organizeService.ts`, `src/main/services/duplicateService.ts`
- System/memory: `src/main/services/systemStats.ts`
- Updates: `src/main/services/updateService.ts`
- v5.3 layers: `src/main/v53/README.md`, `capability.ts`, `judge.ts`, `primitives.ts`,
  `agentLoop.ts`, `security.ts`, `skills.ts`, `voice.ts`, `router.ts`
- Domain types: `src/main/domain/types.ts` (note: there is no `src/main/domain/` service
  layer — file operations live in `src/main/services/`, not in `domain/`; `domain/` holds
  only the `IndexedFile`/`ChunkRecord`/`StoredVector` types)
- UI: `src/renderer/App.tsx`, `src/renderer/pages.ts`, `src/renderer/main.tsx`,
  `src/renderer/index.css`, `src/renderer/components/*.tsx` (ChatMessage,
  DuplicateGroupCard, DuplicatesPage, FileRow, FilesPage, FoldersDialog, MemoryPage,
  OrganizePage, SettingsPage, StatusCards, SystemPage), `src/renderer/utils/fileTypes.ts`
- Bridge: `src/preload/preload.ts`; IPC controllers: `src/main/ipc/ipcControllers.ts`
- Skills (reference only): `skills/find-file.md`, `skills/organize-downloads.md`
- Packaging: `package.json` (`build` section), `src/main/types/pdf-parse.d.ts`
