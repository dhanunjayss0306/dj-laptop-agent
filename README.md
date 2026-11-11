# DJ — your private laptop assistant

DJ lives only on your laptop. You type plain English, DJ finds your
files, understands what is inside them, opens them, and does things
you ask — like organizing today's Downloads. Nothing leaves your
laptop. No paid AI, no account, no cloud. DJ uses your own free local
models in LM Studio.

DJ never moves or deletes anything without showing you first and
getting your Yes.

---

## Before you start

You already have these on your laptop, so there is nothing to buy
or sign up for:

- Python 3.14
- LM Studio, with your chat model (Llama, Qwen, Gemma — whichever
  you use) and the embedding model `nomic-embed-text-v1.5`
- This folder: `dj-laptop-agent` (put it in Downloads if it is
  not there already)

---

## Install — do these steps once

**Step 1.** Open Command Prompt. Press the Windows key + R together,
type `cmd`, press Enter. A black window opens. The last line looks
like this:

```
C:\Users\dhanu>
```

That is your prompt. Every command below is typed after that prompt.
`dhanu` here is only an example — your prompt shows your own
username there. That is normal, just type the same commands.

**Step 2.** Go into the DJ folder. Type this and press Enter:

```
cd Downloads\dj-laptop-agent
```

Your prompt now looks like this:

```
C:\Users\dhanu\Downloads\dj-laptop-agent>
```

**Step 3.** Install the free extra pieces DJ needs. Type this and
press Enter. It downloads from the internet and takes a few minutes.

```
python -m pip install -r requirements.txt
```

Wait until the prompt comes back (the last line is your prompt
again). If you see red errors, see "If something goes wrong" below.

**Step 4.** Start LM Studio and load your models. Open LM Studio
from the Start menu.

1. Load your chat model: click the model name at the top of the
   LM Studio window, pick your model, and wait until it says
   Loaded.
2. Load the embedding model too: click the same model picker at
   the top, search for `nomic-embed-text`, pick it, and wait
   until it loads. It runs at the same time as your chat model.
   (If it is not in your models yet, search for it in the
   Discover tab, download it once — it is free — then load it.)
3. Start the local server: click **Developer** on the left side,
   then click **Start Server**. It should say the server is
   running on port 1234.

Leave LM Studio open while you use DJ. DJ cannot start LM Studio
by itself.

**Step 5.** Start DJ. Go back to the black Command Prompt window
and type this and press Enter:

```
python dj.py
```

The DJ window opens.

That is all. From now on, to open DJ again you only repeat
Steps 1, 2, 4 (make sure LM Studio is open, your model is loaded,
and the server is started) and 5.

---

## First run — pick your folders

The first time DJ opens, a setup window appears. It shows five
folders DJ is allowed to look in:

- Downloads
- Desktop (your Desktop is the OneDrive Desktop — DJ finds it by itself)
- Documents
- Pictures
- Your user files (for example your Antigravity project files)

Change any line if your files live somewhere else. Untick a box to
skip a folder. DJ never looks in the whole C: drive.

Click **Save and build index**. DJ reads your files and builds its
private search index. The first time takes a few minutes — that is
normal. A progress bar shows what it is doing. After that, DJ is
ready.

---

## Try these

Type any of these in the DJ window and press Enter:

```
find my Virun pitch
open something about travel and tourism
summarize my Virun pitch
organize today's Downloads
open notepad
```

- **find ...** — shows the matching files. Click **Open** on any file.
- **open something about ...** — finds files by what is *inside*
  them, opens the best one, and lists the rest.
- **summarize ...** — reads the file and gives a short summary.
- **organize today's Downloads** — shows you a list of what it will
  move, and moves nothing until you click **Yes, move these**.
  It follows your own organizer rules: keyword folders first
  (Virun, SAPSS, SasyaSakhi, Persona, GlobalTap, Quantum,
  HackerRank, VRGym, College), then file-type folders, anything
  left goes to `_Review`. Every move is written to
  `_Organizer_Log.csv` in Downloads. Nothing is deleted, nothing
  is overwritten.
- **open notepad** — opens an installed app by name.

Other buttons in the window:

- **Rebuild index** — click it after you add new files, so DJ
  can find them.
- **Folders...** — change the folders DJ looks in.

---

## What DJ does not do

- No voice, no wake word. Those come later.
- No reminders, calendar or journal. Those are Persona features,
  kept aside for later.
- DJ never sends anything anywhere and never deletes anything.
- If LM Studio is not running, DJ says so plainly, and finding
  files still works (by keyword) without the AI. DJ cannot start
  LM Studio by itself — you start it once, and leave it open
  while you use DJ.

---

## If something goes wrong

**`python` is not recognized as a command.**
Python was not added to PATH. Reinstall Python from python.org
and tick the box **Add Python to PATH** during install.

**`pip install` shows red errors about chromadb.**
DJ still works without it — it falls back to keyword search
(finding by file name and words inside the file). Tell Muse
and it will be fixed. Everything else still installs.

**DJ says "LM Studio is not running".**
Open LM Studio, load your chat model, click **Developer** on the
left, then click **Start Server**. Wait 10 seconds, then click
**Rebuild index** in DJ.

**DJ says the embedding model is not loaded, or search is keyword only.**
In LM Studio, load `nomic-embed-text` as well as your chat model:
click the model picker at the top, search for it, and load it.
Both stay loaded at the same time.

**DJ cannot find a file you just added.**
Click **Rebuild index** and wait for it to finish.

**The first index build is slow.**
That is normal. It only happens once. Later rebuilds are faster.

---

## Files in this folder

| File | What it is |
|---|---|
| `dj.py` | The file you run: `python dj.py` |
| `dj_gui.py` | The chat window |
| `dj_brain.py` | Talking to LM Studio, deciding what to do |
| `dj_indexer.py` | The private search engine (vector + keyword) |
| `dj_actions.py` | Find, open, summarize, organize, open app |
| `dj_config.py` | Settings: your folders and models |
| `requirements.txt` | The free packages to install |
| `dj_config.json` | Created on first run — your saved folders |
| `dj_data/` | Created on first run — DJ's index, on this laptop only |
| `tests/` | Tests that were run on the builder's machine |

## Tested

Tested on a Linux machine (not on Windows yet): 65 checks passed —
indexing and search (keyword + vector), the brain's decisions with a
mock LM Studio server, organizing (plan, move, no-overwrite, log),
and the real window opening under a virtual screen. LM Studio
itself was not running on the test machine, so the LM Studio calls
were tested against a fake LM Studio server. **The first real run
on your Windows laptop is still a test — try the "Try these"
commands and tell Muse what happens.**
