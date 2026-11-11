# DJ — your files, found

DJ is a private desktop app that lives on your laptop and only your laptop. Ask it to find a file and it finds it and opens it. It understands what is **inside** your files, not just their names — so "open something about travel and tourism" opens the files about travel and tourism.

DJ can also:

- **Summarize a file** — it picks the key sentences out of the file itself. DJ has no AI model, so the summary says so plainly.
- **Organize Downloads** — for today, yesterday, the last few days, this week, or everything. It shows you every move first. Nothing moves until you say Yes. Nothing is ever deleted, nothing is ever overwritten.
- **Find duplicate files** — extra copies of the same file. Delete the copies you pick (they go to the Recycle Bin, only after you confirm), or merge a group (keep one copy where it is, move the rest into one folder you pick).
- **Open apps by name** — notepad, chrome, calculator, clock, and more.
- **List recent files.**

DJ never edits what is inside a file. It only finds, opens, deletes, merges, and organizes. Nothing leaves your laptop: no account, no API key, no cloud, no paid service.

## How it works (short version)

1. **Rules** understand your words. Your commands are a fixed set (find, open, summarize, organize, duplicates, delete, merge, open an app), so plain pattern matching is enough — no big model, almost no memory.
2. **Tiny embeddings** understand meaning. A small model (nomic-embed-text-v1.5, about 150 MB) runs inside the app itself, on your CPU. It turns each file into a list of numbers; files about the same thing get similar numbers, so a search for "travel" finds the file about your Chennai trip even if the word "travel" is nowhere in it. If the model cannot load, DJ falls back to plain keyword search — search still works.
3. **Your files stay yours.** The index lives in a folder on your laptop only.

## First run on your laptop (Windows)

You need Node.js first. Do it exactly like this.

### Step 1 — Install Node.js

1. Open your browser and go to **https://nodejs.org**
2. Click the big green button that says **LTS** (Long Term Support). Download it.
3. Run the downloaded installer. Click **Next** through every screen. Leave every box ticked as it is.
4. When it finishes, close the installer.

### Step 2 — Check Node.js installed

1. Press the **Windows key**, type `cmd`, press **Enter**. A black window opens.
2. Type this and press **Enter**:

   ```text
   node --version
   ```

   You should see something like `v22.14.0`. Any version 20 or higher is fine.
3. Type this and press **Enter**:

   ```text
   npm --version
   ```

   You should see a version number like `10.9.2`.

If either command says "not recognized", close the black window, open it again, and try once more. If it still fails, install Node.js again from Step 1.

### Step 3 — Get DJ

1. In the same black window, type this and press **Enter** (replace `dhanu` with your Windows username if it is different):

   ```text
   cd C:\Users\dhanu
   ```

2. If you already have DJ's folder from before, update it:

   ```text
   cd dj-app
   git pull
   ```

   If you do not have it yet, ask Muse for the folder — DJ is not published anywhere, it comes from your own copy.

### Step 4 — Install DJ's parts

1. In the black window, make sure you are inside the `dj-app` folder. The line at the top of the window should end with `dj-app>`. If it does not, type:

   ```text
   cd C:\Users\dhanu\dj-app
   ```

2. Type this and press **Enter**. It downloads DJ's parts (about a minute, one time only):

   ```text
   npm install
   ```

   Wait until it finishes and the `>` prompt comes back.

### Step 5 — Start DJ

Type this and press **Enter**:

```text
npm start
```

DJ's window opens. The first time, it asks you to confirm the 5 folders it will search (Downloads, Desktop, Documents, Pictures, and your Antigravity folder). Tick the ones you want, click **Save**, and DJ builds its index. The first build takes a few minutes — the progress bar shows what it is doing. The tiny embedding model also downloads the first time (about 150 MB, once only); after that it is saved on your laptop.

That is it. From then on, just run `npm start` from the `dj-app` folder whenever you want DJ.

### If DJ's window does not open

- Make sure the black window says you are in the `dj-app` folder (`cd C:\Users\dhanu\dj-app`).
- Run `npm install` again, then `npm start` again.
- If Windows Smart App Control blocks something, do **not** turn Smart App Control off — once off, it cannot be turned back on without reinstalling Windows. Send Muse the exact message on the screen instead.

## For developers

```
dj-app/
  src/
    main/            Electron main process (Node.js + TypeScript)
      main.ts        App entry: window, wiring
      config.ts      Config load/save (dj_config.json)
      ipc/           IPC controllers (routes layer)
      services/      Business logic, one file per job
        brainService.ts      Rules that understand commands
        indexService.ts      File walk, chunking, search
        vectorStore.ts       Brute-force cosine search over vectors
        embedderClient.ts    Asks the renderer to embed texts
        fileReader.ts        Read txt/md/pdf/docx/code
        organizeService.ts   Downloads organizer (preview first)
        duplicateService.ts  Duplicates: find, delete, merge
        summarizeService.ts  Extractive summary (no LLM)
        appLauncher.ts       Open apps by name
        chatService.ts       One message in, one answer out
      repositories/  Disk storage (keyword index, vectors)
      utils/         paths, text, hashing
    renderer/        React 19 + Astryx (the app window)
      embedder.ts    The tiny model, running in the window (WASM ONNX)
      main.tsx       Entry: Theme provider, embedder wiring
      App.tsx        Chat UI
    preload/         The only bridge: window.dj
    shared/          Types + IPC channel names (both sides)
  tests/             Vitest: brain, organize, duplicates,
                     vector store, indexer, embedder
```

Layers, like a Java project: **ipc** (routes) → **services** (logic) → **repositories** (disk). One responsibility per file, typed interfaces everywhere.

### Scripts

```text
npm run dev      Develop: Vite + Electron with live reload
npm start        Run the built app
npm run build    Build main (tsc) + renderer (Vite)
npm test         Run the test suite (Vitest)
npm run pack     Build + make a Windows installer (needs Windows)
```

### Notes

- The embedding model is `Xenova/nomic-embed-text-v1.5` via `@huggingface/transformers`, running in the renderer (Chromium) with the WebAssembly ONNX backend. It runs there on purpose: the native ONNX module does not load inside Electron's Node, and fixing that would need a C++ build toolchain on your laptop. The main process asks the renderer to embed over IPC (`dj:embed-request` / `dj:embed-response`).
- The model needs `search_document: ` in front of indexed chunks and `search_query: ` in front of searches. The main process adds them; the stored texts are unchanged.
- Vector search is brute-force cosine over stored vectors (persisted as `vectors.bin` + `vectors_meta.json` in the app data folder). At this scale (a few thousand chunks) it is fast and has no native dependency.
- The Windows installer (`npm run pack`) has not been fully tested: on a Linux machine the unpacked Windows app (`DJ.exe`) builds fine, but the NSIS installer step needs Windows (or wine) and fails without it. Build the installer on Windows, or ship the unpacked folder. `npm start` is the tested way to run DJ.
- The first time DJ needs meaning search, it downloads the tiny model (~150 MB) from the Hugging Face hub. That needs normal internet access to huggingface.co. If the download fails (no internet, blocked network), DJ says so in the status bar ("embedder not available") and keeps working with keyword search — nothing breaks, it just cannot find files by meaning until the model downloads.
- No Python, no LM Studio, no Ollama, no cloud API, no API key, no paid service.
