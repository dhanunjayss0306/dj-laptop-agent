# DJ — your files, found

DJ is a private assistant that lives on your Windows laptop and your Android phone. One app, same DJ on both. Ask it to find a file and it finds it and opens it. It understands what is **inside** your files, not just their names — so "open something about travel and tourism" opens the files about travel and tourism.

DJ also sees your screen, talks to you by voice, points at things on screen, and can drive your computer for you — like an AI buddy sitting next to you.

This is the Flutter version of DJ. There is no Electron here. The old Electron version still lives in this repo's git history.

## What DJ can do

- **Find, open, delete, merge files** — DJ never edits what is inside a file. It only finds, opens, deletes, merges, and organizes.
- **Summarize a file** — it picks the key sentences out of the file itself.
- **Organize Downloads** — for today, yesterday, the last few days, this week, or everything. It shows you every move first. Nothing moves until you say Yes. Nothing is ever deleted, nothing is ever overwritten.
- **Find duplicate files** — extra copies of the same file. Delete the copies you pick (they go to the Recycle Bin, only after you confirm), or merge a group.
- **Open apps by name** — notepad, chrome, calculator, clock, and more.
- **See your screen** — press the hotkey and DJ sees what you see. It only looks when you press the hotkey. Screenshots are never stored.
- **Privacy Screen (laptop only)** — the webcam watches whether you are looking at the screen. Look away, walk off, or someone looks over your shoulder, and the whole screen goes black until only you are looking again. Press Ctrl+Alt+P anywhere to pause it and reveal the screen; press again to resume. Fully local — on-device face detection, no network, no keys, frames never saved. Based on SafeScreen by kv4u (MIT), see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- **Point and draw on your screen** — DJ points at exactly where to click, and draws circles and arrows to show the way.
- **Talk to you** — ask out loud, DJ answers out loud. On Windows it uses a local speech model (whisper.cpp, offline, no key). On the phone it uses Android's built-in speech.
- **Walk you through tasks** — step-by-step walkthroughs, all the way to done. DJ can also teach you any tool on screen.
- **Agents that do tasks** — say "DJ agent" and DJ goes and does the task itself: research, write, build, operate the computer. Real clicks and typing, with a step limit and safety rules.
- **Routines** — save a routine and run it again any time. A morning routine and a wind-down routine are built in.
- **Your apps** — WhatsApp, Gmail, Google Drive, GitHub, Instagram, Chrome, Opera.
- **Same account on both** — one DJ login on laptop and phone. Routines, settings, and memory sync. DJ works fully offline without an account.

## How the AI works

DJ has three layers, and it falls back down the list:

1. **Cloud** — a frontier model through DJ's own Cloudflare Worker proxy (keys never ship in the app).
2. **Local** — a small model on your own machine.
3. **Core** — always works, no model, no key, no internet. File search, open/delete/merge, organize, duplicates, routines, settings.

Asking a question and getting an answer **needs AI** (Cloud, Local, or a Claude agent). Searching files does **not** need AI — it uses DJ's local vector database (embeddings) on your own machine.

See [AI-MODES.md](AI-MODES.md) for exactly what works with internet, with a local AI agent, and with no internet at all.

## Install (no tools needed)

Download DJ from **Releases** on this repo's GitHub page:

- **Android phone:** download the `.apk` file, open it on your phone, tap Install.
- **Windows laptop:** download the Windows `.zip`, unzip it, run `dj.exe`.

You do not need to install Flutter, Android Studio, or Visual Studio. GitHub Actions builds both installers on every release — see [.github/workflows/build.yml](.github/workflows/build.yml).

## Build it yourself

If you want to build from source, see [WINDOWS-BUILD.md](WINDOWS-BUILD.md). It covers both the Windows `.exe` and the Android `.apk` from a Windows laptop.

## Setup (optional, for the cloud parts)

- **Same account on laptop and phone:** create a Firebase project — see [FIREBASE-SETUP.md](FIREBASE-SETUP.md). Until then DJ works fully offline.
- **Cloud AI, voice, and integrations:** deploy the Cloudflare Worker in `worker/` — see [worker/README.md](worker/README.md). Until then DJ runs on Core only.

## Privacy

- Nothing leaves your laptop or phone unless you use a cloud feature.
- Screenshots are memory-only and never stored.
- Privacy Screen camera frames are memory-only and never saved to disk. Face detection runs on the laptop; nothing is sent anywhere.
- DJ keeps only short text summaries for context. You can delete all DJ data in Settings.
- No account is needed. No API key is needed for Core.

## Project layout

- `lib/` — the Dart app (core brain, services, platform channels, UI, features).
- `android/` — Android runner + Kotlin native code (screen capture, overlay, AccessibilityService, speech).
- `windows/` — Windows runner + C++ native code (screen capture, overlay, SendInput, hotkey, tray, Privacy Screen webcam capture).
- `worker/` — Cloudflare Worker proxy for the cloud AI keys.
- `test/` — 311 tests.
- `PORTING-SPEC.md` — how the Electron DJ was ported to Flutter, and what was found.

## History

- **Flutter DJ (now):** one app for Windows laptop + Android phone. See the git log.
- **Electron DJ (before):** the old version is still in this repo's git history, up to commit `9b712ef` (v5.6.0). Nothing was deleted from history.
