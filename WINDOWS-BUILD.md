# DJ — build on your Windows laptop (and Android APK)

DJ is a Flutter app: one codebase, two builds. The Windows `.exe` and the
Android `.apk` are both built from this folder (`dj-flutter`).

**Why build on the laptop:** the Linux VM this code was written on cannot
run Gradle builds at all — its sandbox blocks the JVM loopback TCP the
Gradle daemon needs, so `flutter build apk` fails there even with
`--no-daemon`. The laptop has no such restriction. Build both outputs
here, on Windows.

**What you need on the laptop:** Windows 10 or 11 (64-bit), about 10 GB
free disk, and an internet connection for the one-time downloads.

---

## 1. Install Flutter

1. Download the Flutter SDK zip for Windows (stable) from
   https://docs.flutter.dev/get-started/install/windows — pick the
   latest stable (this project was written against Flutter 3.35.7;
   a newer stable is fine).
2. Extract it to `C:\flutter` (not inside `C:\Program Files`, not inside
   a OneDrive folder).
3. Add `C:\flutter\bin` to your PATH:
   Start menu > type "environment variables" > Edit the system
   environment variables > Environment Variables > under User variables
   select Path > Edit > New > `C:\flutter\bin` > OK on every window.
4. Open a NEW Command Prompt or PowerShell and run:
   ```
   flutter --version
   flutter doctor
   ```
   `flutter doctor` will complain about missing Android Studio and
   Visual Studio at this point — that is expected, fix it in steps 2
   and 3 below.

## 2. Install Visual Studio (for the Windows .exe)

The Windows build needs the C++ compiler. Install Visual Studio 2022
Community (free) from https://visualstudio.microsoft.com/downloads/.

1. Run the installer. On the Workloads screen, tick
   **Desktop development with C++** (this is the only workload DJ needs).
2. On the right, under Installation details, make sure these are ticked:
   MSVC v143, Windows 11 SDK (or Windows 10 SDK), and C++ CMake tools.
3. Install. It is a large download; let it finish.
4. Run `flutter doctor` again. The Visual Studio line should now be
   green (a check mark). If it still shows a problem, run
   `flutter doctor -v` and read the Visual Studio section.

## 3. Install Android Studio (for the Android .apk)

1. Install Android Studio from
   https://developer.android.com/studio (the standard installer).
2. Open Android Studio once. It runs a first-run setup wizard that
   installs the Android SDK — accept the defaults.
3. In Android Studio: SDK Manager (gear icon > SDK Manager) > SDK
   Platforms tab > tick **Android 15.0 (API 35)** if it is not already
   ticked > Apply. Then SDK Tools tab > tick **Android SDK Build-Tools**
   and **Android SDK Command-line Tools** > Apply.
4. Run `flutter doctor --android-licenses` and press `y` for every
   prompt (this accepts the Android SDK licences).
5. Run `flutter doctor`. Everything should be green except possibly
   Chrome (not needed) and the "Visual Studio not installed" line if
   step 2 is not done yet.

## 4. Get the DJ project onto the laptop

Copy the whole `dj-flutter` folder onto the laptop, for example to
`C:\Users\dhanu\dj-flutter`. Keep the folder structure exactly as it
is — do not rename anything inside it. (If the project lives in a git
repo by then, clone it instead.)

Then, in a Command Prompt or PowerShell inside that folder:

```
cd C:\Users\dhanu\dj-flutter
flutter pub get
```

`flutter pub get` downloads the packages DJ uses (Firebase, path
provider, and the rest). It needs internet the first time only.

## 5. Build the Windows .exe

```
flutter build windows --release
```

First build takes several minutes (it compiles the C++ runner and the
Dart code). Later builds are faster.

**Output:** `build\windows\x64\runner\Release\dj.exe`, plus its DLLs
and the `data` folder next to it. DJ runs from that folder — copy the
whole `Release` folder if you move it somewhere else, not just the
`.exe` alone.

**Run it:** double-click `dj.exe`. The window is 880 x 720 and titled
"DJ — your files, found".

**First run — what to expect:**
- The first screen is "Set up DJ": pick the folders DJ searches
  (Downloads, Desktop, Documents, Pictures, and home are the defaults).
  DJ never indexes the whole drive unless you add a folder.
- The tray icon appears only if a `tray-icon.ico` file sits next to
  the exe or in `Release\data\flutter_assets` — copy
  `windows\runner\resources\app_icon.ico` to
  `build\windows\x64\runner\Release\tray-icon.ico` to enable it.
  With the tray, closing the window hides DJ to the tray (right-click
  the tray icon > Quit DJ to quit). Without the tray file, closing the
  window quits DJ.
- The global hotkey is **Ctrl+Alt+D** — press it anywhere and DJ looks
  at your screen. If Windows says the hotkey is already in use, pick
  another one in Settings (the app reports the conflict plainly).
- Start-at-login is a switch in Settings (it writes the Windows Run
  registry key, no admin needed).

**If the build fails:** read the error first. Common causes:
- "Visual Studio not found" — step 2 is not finished, or the C++
  workload is missing. Run `flutter doctor -v`.
- A C++ compile error in `windows\runner\dj_*.cpp` — the native code
  was written on Linux and never compiled on Windows. The error names
  the file and line; fix that one spot and rebuild. The code was
  written to be compile-clean by inspection (see
  `windows\README-DJ.md`), but the first Windows compile is the real
  test.
- "CMake ... not found" — the C++ workload in step 2 did not include
  CMake. Re-run the Visual Studio installer > Modify > tick C++ CMake
  tools.

## 6. Build the Android .apk

```
flutter build apk --debug
```

For a phone install you can also build release later
(`flutter build apk --release`); debug is the right first test because
it installs without signing setup.

**Output:** `build\app\outputs\flutter-apk\app-debug.apk`.

**Install it on the Samsung Galaxy S24 FE:**
1. Copy the `.apk` to the phone (USB, or upload it to Google Drive
   and download it on the phone).
2. On the phone, tap the `.apk` file. Android will ask to allow
   "Install unknown apps" for the app you opened it from (Files, or
   Drive) — allow it once.
3. Open DJ. The first screen is the same "Set up DJ" folders screen.
4. DJ on Android needs three permissions, granted by hand in Settings:
   - **Display over other apps** — for the floating DJ button and the
     fake cursor overlay. Android asks the first time DJ tries to show
     it; if you miss the prompt, go to Settings > Apps > DJ >
     Display over other apps.
   - **Accessibility (DJ)** — for real tapping and typing. Go to
     Settings > Accessibility > Installed apps > DJ > turn it on.
     Android shows a warning; this is the same permission Tapr-style
     apps use. DJ refuses password fields and never types passwords.
   - **All files access** (or the folder picker) — for reading your
     files. DJ asks through the system folder picker when you add a
     folder.
5. The floating DJ button appears when DJ is in the background — tap
   it and DJ looks at your screen. It hides itself while DJ is in the
   foreground.

**If the build fails:** the usual cause is a missing Android SDK
component or an unaccepted licence — run `flutter doctor` and
`flutter doctor --android-licenses` and fix what it names.

## 7. Optional setup (after the first successful build)

Do these only after the app itself builds and runs. None of them is
needed for DJ Core (offline file search, open, organise, duplicates),
which works with no account and no keys.

### 7a. Voice on Windows (whisper.cpp sidecar, offline, no key)

Speech-to-text uses a local whisper.cpp server. Text-to-speech uses
Windows SAPI and needs nothing.

1. Download `whisper-server` for Windows from the whisper.cpp
   releases (https://github.com/ggerganov/whisper.cpp/releases) —
   the `whisper-bin-x64.zip` (or similar) for your CPU.
2. Download a ggml model, for example `ggml-base.en.bin` (English
   only, ~140 MB) from https://huggingface.co/ggerganov/whisper.cpp.
   The small multilingual `ggml-small.bin` also works.
3. Put `whisper-server.exe` and the model file next to `dj.exe`
   (in `build\windows\x64\runner\Release\`), or put them in a
   `whisper` subfolder there.
4. In DJ, voice answers use the sidecar automatically when it is
   present. If it is missing, DJ says "whisper not installed" and
   never invents a transcript.

### 7b. Cloud (Worker proxy) — for the model chat, vision, and cloud TTS

DJ never holds an AI provider key in the app. The keys live in a
Cloudflare Worker (see `worker/README.md` for the full steps).

1. Create a free Cloudflare account, then deploy the Worker from the
   `worker/` folder (`wrangler deploy`) and set the five secrets
   (OpenAI, OpenRouter, Anthropic, AssemblyAI, ElevenLabs keys).
2. In DJ, go to Settings > Cloud and paste the Worker URL
   (`https://dj-proxy.<your-subdomain>.workers.dev`) and pick the
   provider. Keys stay in the Worker, never in the app.
3. Vision (ScreenQA) needs a vision-capable model: `gpt-4o` for
   OpenAI/OpenRouter, `claude-sonnet-4-5` for Anthropic. A text-only
   model rejects the screenshot and DJ says so plainly.

### 7c. Account + sync (same DJ on laptop and phone)

One DJ login (email + password you choose) syncs routines, settings,
summaries and memory between the laptop and the phone. DJ works fully
offline without an account; the account is only for sync.

Follow `FIREBASE-SETUP.md` exactly (create the Firebase project under
your own Google account, enable Email/Password auth, create the
Firestore database, paste the security rules, add the Android app
`com.dhanunjay.dj`, download `google-services.json` into
`android\app\`, run `flutterfire configure`). Then rebuild both apps.
Without this setup the Account card in Settings says so plainly and
DJ keeps working offline.

### 7d. Gmail / Drive / GitHub integrations

These need your own credentials, created by you:
- Gmail and Google Drive: a Google Cloud OAuth client (desktop app
  type). Put the client ID and secret in DJ Settings > Integrations.
- GitHub: a personal access token (repo scope, read-only use).
- WhatsApp and Instagram: deep links only, no login needed.

## 8. Updating DJ later

1. Copy the new `dj-flutter` folder over the old one (keep
   `%APPDATA%\DJ\dj_data` — that is where your index, config and
   memory live; an update never touches it).
2. Run `flutter pub get`, then `flutter build windows --release`
   (and `flutter build apk --debug` for the phone).
3. Close DJ fully first (right-click the tray icon > Quit DJ), then
   replace the `Release` folder, then start it again.

## 9. What is NOT built yet (honest list)

- The Windows C++ code has never been compiled — no Visual Studio
  exists on the Linux VM. The first `flutter build windows` is the
  real compile test; expect to fix a small number of compile errors
  (see `windows\README-DJ.md`).
- The Android APK has never been built — Gradle cannot run on the
  Linux VM (see the note at the top). The first `flutter build apk`
  on the laptop is the real test.
- Nothing has run on a real phone yet. The Android native code
  (Kotlin) compiles clean, but the floating button, overlay,
  AccessibilityService and MediaProjection capture are untested on
  hardware.
- The Cloudflare Worker and the Firebase project do not exist yet —
  both are set up by you (sections 7b and 7c). Until then DJ runs on
  Core only, which is fully working offline.
- Gmail, Drive and GitHub are not connected until you add your OAuth
  client / token (section 7d).

## Quick command reference

```
cd C:\Users\dhanu\dj-flutter
flutter pub get
flutter build windows --release
flutter build apk --debug
```

Windows exe: `build\windows\x64\runner\Release\dj.exe`
Android apk: `build\app\outputs\flutter-apk\app-debug.apk`
