# DJ — the 4 AI modes

DJ's AI works in 4 different ways, depending on what you have: internet, a computer or a phone, and whether a local AI agent on your laptop is driving it. This page says, in plain words, what works in each case.

## The one rule to remember

**Asking a question and getting an answer NEEDS AI.** The answer comes from a Cloud model, a Local model, or a local agent. No AI, no answer.

**Searching your files does NOT need AI.** Search uses DJ's local vector database (embeddings) on your own machine. It finds files by meaning, without any model answering anything.

Those are two different jobs. Do not mix them up.

---

## Mode 1 — Internet + computer (Windows laptop)

**What it is:** DJ on your Dell laptop, with internet.

**What works — everything:**

- **Cloud AI answers:** ask a question about your files and DJ answers it. DJ searches your files (vector + keyword), gives the matching files' text to the cloud model as context, and the model answers in words, with the source files listed. Asking works through the Cloudflare Worker proxy — DJ's own Worker, your keys never sit in the app.
- **Vision / screen Q&A:** press the hotkey, DJ sees your screen and answers questions about what is on it.
- **Fake cursor:** DJ points at exactly where to click, and draws circles and arrows on your screen.
- **Real clicking and typing:** DJ drives your computer (SendInput) — clicks, types, opens apps. 15-step limit per task, stuck detection, and DJ shows where it will click before it clicks. It never types passwords.
- **Streaming voice:** speak and DJ turns it into text (whisper.cpp sidecar, runs on your laptop, offline, no key), and DJ answers back out loud.
- **Agents:** say "DJ agent" and DJ does the task itself — research, write, build, operate the computer.
- **Walkthroughs:** step-by-step guidance, all the way to done. DJ can teach you any tool on screen.
- **Routines:** save a routine and run it again. Morning routine and wind-down are built in.
- **Your apps:** WhatsApp, Gmail, Google Drive, GitHub, Instagram, Chrome, Opera.
- **Same account:** one DJ login on laptop and phone, routines, settings, and memory sync.
- **Global hotkey:** Ctrl+Alt+D works anywhere on Windows.

**Fallbacks:** if the cloud is down, DJ falls back to the Local model, then to Core. Core always works with no model and no key.

**What you need set up:** the Cloudflare Worker deployed (see `worker/README.md`) for cloud answers and voice; a Firebase project (see `FIREBASE-SETUP.md`) for the same account and sync. Until then, DJ runs on Core only — unless a local model is running, in which case local answers work.

**Local answers are wired.** DJ tries the cloud first, then the local model (Ollama first, then LM Studio, then Core). Pick the model in Settings → Local model, and switch on "Answer with the local model first" to make Local the first try. The answer says which model answered, for example "answered by qwen3.5:9b on your laptop".

---

## Mode 2 — Internet + phone (Android)

**What it is:** DJ on your Samsung phone, with internet. Same DJ, adapted for a phone.

**What works — everything, the phone way:**

- **Cloud AI answers:** same as the laptop — ask about your files, DJ answers with sources.
- **Screen seeing:** DJ sees your phone screen (MediaProjection) and answers questions about it.
- **Fake cursor overlay:** DJ points at things on your phone screen.
- **Real taps:** DJ taps, swipes, and types on your phone through the AccessibilityService (you switch it on once, by hand, in Settings — like Tapr). Same safety rules as the laptop: 15-step limit, stuck detection, show before tapping, never types passwords.
- **Voice:** Android's built-in speech recognition turns your words into text; DJ answers out loud.
- **Agents, walkthroughs, routines, your apps:** same as the laptop.
- **Same account:** the same DJ login as your laptop; routines, settings, and memory sync.

**What is different from the laptop:**

- **No global hotkey.** Android has no global hotkey, so DJ uses a floating DJ button on screen instead. Tap it to talk to DJ.
- **No whisper.cpp sidecar.** The phone uses Android's own speech recognition, not the laptop's local speech model.

**What you need set up:** same as the laptop — the Worker deployed, a Firebase project. DJ works fully offline without an account.

**Gap, honestly:** local-model answering only works on the laptop (Ollama and LM Studio run on the computer, not on the phone), and on Android the browsers integration cannot pass a URL yet (`listApps` and `openUrl` are missing on the Android system channel).

---

## Mode 3 — Internet + a local AI agent as the brain

**What it is:** the full-power mode. The agent runs LOCALLY on your own laptop — not in the cloud. It is a local AI agent: local models through Ollama (for example qwen3.5:9b or qwen2.5-coder:7b, already on your laptop), or a local agent such as Claude Code running on your machine. DJ's agent loop gives it tools — screen, click, files, integrations — and the local agent decides what to do, on your hardware.

**What works in this mode:**

- **Everything in Mode 1, plus a local agent doing the thinking.** Research, write, build, operate the computer — the local agent plans the steps, DJ's agent loop runs them.
- **The thinking stays on your laptop.** The model runs on your hardware. The agent can use the internet for tools and search when a step needs it, but the brain itself is local — no cloud agent involved.
- **Local-model answers are wired.** Ask a question and DJ answers with the local model when the cloud is not there, or when you pick Local first in Settings. The answer says which model answered, for example "answered by qwen3.5:9b on your laptop".

**What you need set up:** Ollama running (`ollama serve`) with a model pulled (`ollama pull qwen3.5:9b`), or the LM Studio server started. Pick the model in Settings → Local model.

**Gap, honestly:** a local Claude agent (for example Claude Code running on your laptop) driving DJ's agent loop directly is **not wired yet**. The agent loop and all its tools exist, and local-model answering through Ollama / LM Studio works — but plugging a local Claude agent in as the brain is still to build.

---

## Mode 4 — No internet (both laptop and phone)

**What it is:** DJ with no internet at all, on either device. Core only.

**What works:**

- **File search:** keyword search over file names and file text. Works fully, no internet, no model.
- **Open / delete / merge files:** DJ never edits what is inside a file.
- **Organize Downloads, find duplicates, list recent files.**
- **Local routines, settings.**
- **Meaning search — only for old files:** if you used the Electron DJ before, its stored vectors still load, so meaning search works for the files it already embedded.

**What does NOT work:**

- **No cloud AI answers.** But a local model still works offline: if Ollama or LM Studio is running on your laptop, DJ answers your questions with the local model, no internet needed. On the phone there is no local model, so no answers there without internet.
- **No vision / screen Q&A.** No cloud model to look at the screen.
- **No cloud voice.** No streaming transcription, no cloud text-to-speech. (On the laptop, the whisper.cpp sidecar is local, so dictation can still work offline once it is bundled — see the gap below.)
- **No integrations.** Gmail, Drive, GitHub, WhatsApp, Instagram all need internet.
- **No sync.** The laptop and the phone cannot share anything without internet.

---

## Gaps, honestly (what is NOT built yet)

1. **The local embeddings model is not bundled.** DJ's vector database exists (768-dim cosine search, same format as the Electron app), and it loads old vectors from the Electron DJ. But the embedding model itself (nomic-embed-text-v1.5, 131 MB ONNX) is **not** in the Flutter app, and no ONNX runtime runs in it. So new or changed files get keyword search only — no meaning search for them — until a real embedder is plugged in behind the `Embedder` interface. This is not faked anywhere: when meaning search is unavailable, DJ says so plainly.
2. **Local-model answering is wired.** DJ answers with a local model (Ollama first, then LM Studio, then Core) when the cloud is not there, or when you pick Local first in Settings → Local model. The remaining piece is a local Claude agent driving DJ's loop directly (see Mode 3).
3. **A local Claude agent as the brain is not wired.** See Mode 3.
4. **Firebase and the Worker need your setup.** Until you create the Firebase project and deploy the Worker, there is no same-account sync and no cloud AI — DJ runs on Core only. Steps are in `FIREBASE-SETUP.md` and `worker/README.md`.
5. **Nothing has run on real hardware yet.** The Windows C++ and the Android Kotlin code are written but untested on a real laptop and phone. The first `flutter build windows` and the first install on your phone are the real tests.
