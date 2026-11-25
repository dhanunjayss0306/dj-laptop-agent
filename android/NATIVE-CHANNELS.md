# DJ Android native channels — reference for the Dart side

Native code lives in `android/app/src/main/kotlin/com/dhanunjay/dj/`.
Channel names are identical to the Windows side. Every method returns a
`Map` with `{ok, message}` (plus data) and never throws across the channel.

## com.dhanunjay.dj/system — SystemChannelHandler.kt

| Method | Args | Returns / notes |
|---|---|---|
| `openFile` | `path` | Opens with ACTION_VIEW + FileProvider. |
| `openFolder` | `path` | Tries the file manager; falls back to opening the Files app home view (Android has no intent that opens an arbitrary path), or `{ok:false}` when no file manager exists. |
| `openApp` | `exe` (or `packageName`/`name`) + ignored `args` | Launch by package name, else by installed app label (exact, then contains). |
| `deleteToTrash` | `path` | Moves the file to `<externalFilesDir>/.trash/`, records the original path in `.trash-meta.json`. Returns `{ok, message, trashPath}`. Never permanently deletes. |
| `restoreFromTrash` | `trashPath` (or `path`) | Moves it back to its original path (free name with `-1`, `-2` on clash). |
| `getSystemStats` | — | `{cpuPercent, cpuCores, totalMemBytes, freeMemBytes, uptimeSeconds, platform}` — the byte/second keys match the Dart `SystemStats` model — plus extras `ramUsedMb, ramTotalMb, ramPercent, uptimeMs, uptime`. `cpuPercent` is null if `/proc/stat` cannot be read. |
| `setStartAtLogin` | `enabled` | Always `{ok:false, message:'not available on Android'}`. |
| `getHomeDir` | — | `{homeDir}` = app external files dir, plus `externalStorage` root. |
| `getDownloadsDir` | — | `{path}` = public Downloads folder. |
| `pickFolder` | — | SAF `ACTION_OPEN_DOCUMENT_TREE`. Returns `{uri, path (= uri string), name}`. SAF tree URIs are **not** filesystem paths — store the URI string. |

## com.dhanunjay.dj/screen — ScreenCaptureHandler.kt

| Method | Args | Returns / notes |
|---|---|---|
| `captureScreen` | — | One-shot MediaProjection capture → `{png: Uint8List, width, height}`. Shows the system permission prompt on first use; a decline returns `{ok:false, message:'screen capture permission not granted — allow it in the prompt'}`. A `mediaProjection` foreground service is started for the capture and stopped right after (Android 14+ rule). No streaming in v1. |

## com.dhanunjay.dj/cursor — CursorOverlayHandler.kt

| Method | Args | Notes |
|---|---|---|
| `showCursor` | `x, y, label` | Blue (#0071E3) pointer + white label bubble in a `TYPE_APPLICATION_OVERLAY` window. |
| `moveCursor` | `x, y, label` | Animates (~250 ms) to the new spot. |
| `hideCursor` | — | Removes the overlay. Also clears any annotations. |
| `annotate` | `annotations` (list of maps) | Draws on a separate full-screen overlay window, same DJ blue, still click-through. Each map is one shape: `{'type': 'circle', 'x': x, 'y': y, 'r': r}` (outline circle), `{'type': 'arrow', 'x1': x1, 'y1': y1, 'x2': x2, 'y2': y2}` (line + arrowhead), `{'type': 'rect', 'x': x, 'y': y, 'w': w, 'h': h}` (translucent blue fill + solid border), `{'type': 'text', 'x': x, 'y': y, 'text': text}` (white label bubble). Replaces any annotations already shown; an empty list clears. Works even when the cursor itself is hidden. Coordinates are screen pixels. |
| `clearAnnotations` | — | Clears all annotations. A showing cursor stays showing. |

Overlay is `FLAG_NOT_TOUCHABLE | FLAG_NOT_FOCUSABLE` — it never intercepts
touches and never moves the real pointer. Needs "Display over other apps";
without it every call returns `{ok:false, message:'overlay permission not
granted — allow "Display over other apps" in Settings'}`.

## com.dhanunjay.dj/floatingbutton — FloatingButtonHandler.kt

Android has no global hotkey, so this is the Android equivalent: a small
draggable blue circle with "DJ" text that floats over other apps. Tapping
it fires `onHotkeyPressed` on the **hotkey** channel
(`com.dhanunjay.dj/hotkey`) — the same event the Windows global hotkey
feeds — so the existing Dart `HotkeyChannel.onHotkeyPressed` stream
receives taps with no extra wiring. This channel only manages visibility.

| Method | Args | Notes |
|---|---|---|
| `showFloatingButton` | — | Shows the button. If DJ is in the foreground it reports `{ok:true, message:'floating button will show when DJ is in the background'}` and appears automatically once DJ is backgrounded. |
| `hideFloatingButton` | — | Hides it. |
| `setFloatingButtonVisible` | `visible` (bool) | Show/hide by flag. |

Same overlay window mechanism as the cursor overlay
(`TYPE_APPLICATION_OVERLAY`, `SYSTEM_ALERT_WINDOW` permission — already
declared in `AndroidManifest.xml`, no new permission). The window is only
as big as the button itself (~56 dp), so touches anywhere else pass
through to the app underneath; the button never blocks other touches.
Touch-drag moves it (clamped to the screen); a tap (down + up with
under ~10 dp of movement) fires the hotkey event. Hidden while DJ's own
app is in the foreground (tracked with
`Application.ActivityLifecycleCallbacks`); Dart only needs to call
`showFloatingButton()` once, e.g. at startup.

Dart helper: `lib/platform/floating_button_channel.dart`
(`FloatingButtonChannel.showFloatingButton()` /
`hideFloatingButton()` / `setFloatingButtonVisible(bool)`). All methods
never throw; without the overlay permission they return false.

## com.dhanunjay.dj/input — InputChannelHandler.kt + DJAutomationService.kt

| Method | Args | Notes |
|---|---|---|
| `tap` | `x, y` | `dispatchGesture`, ~80 ms stroke. |
| `swipe` | `x1, y1, x2, y2, durationMs?` | Default 300 ms. |
| `moveMouse` | `x, y` | Android has no real pointer: moves the **fake cursor overlay** to (x, y) and remembers the spot for `click`. Needs the overlay permission. |
| `click` | `button` (`left` only) | Taps at the last `moveMouse` spot; fails plainly if the cursor was never moved. |
| `typeText` | `text` | `ACTION_SET_TEXT` on the focused field. **Refused on password fields.** |
| `pressKey` | `key` | `back \| escape \| home \| recents \| alt+tab \| notifications \| quickSettings`. Arbitrary keys (Enter, Tab, Ctrl+C…) cannot be injected by an AccessibilityService and return `{ok:false}` with the supported list. |
| `isAccessibilityEnabled` | — | `{ok, enabled}`. |
| `openAccessibilitySettings` | — | Deep-links to Settings → Accessibility. |

Dart helper: `lib/platform/android_accessibility.dart`
(`AndroidAccessibility.isAccessibilityEnabled()` /
`openAccessibilitySettings()`).

## com.dhanunjay.dj/voice — VoiceChannelHandler.kt

| Method | Args | Notes |
|---|---|---|
| `startListening` | — | SpeechRecognizer, language `en-IN` (device default fallback). Returns `{ok, message}` only; results arrive as channel events (same channel name): `onPartialResult {text}`, `onFinalResult {text}`, `onSpeechError {error, message}`, `onListeningStarted`, `onListeningStopped`. Asks for RECORD_AUDIO on first use; call again once granted. |
| `stopListening` | — | Ends listening (final result still delivered). |
| `speak` | `text` | System TextToSpeech, en-IN then device default. Offline when a voice pack is installed. |
| `stopSpeaking` (alias `stopSpeak`) | — | Stops TTS. |
| `startWhisper` / `transcribe` / `whisperStatus` | — | Windows-only whisper sidecar: on Android these return `{ok:false}` saying to use `startListening` instead. |

No API key, no model download, no network speech service. Cloud STT
(AssemblyAI) is a Cloud-layer option only, not Core.

## One-time setup the user must do on the phone (Galaxy S24 FE)

1. **Accessibility (real input):** Settings → Accessibility → Installed apps
   (or Downloaded apps) → DJ → on. The service only acts when Dart calls it.
2. **Overlay (fake cursor + annotations + floating button):** Settings → Apps → DJ → "Display over other apps"
   → allow. (Android may also prompt on first use.) The floating button
   uses this same permission — no separate grant is needed. Once allowed,
   the button appears whenever DJ is in the background and hides itself
   while DJ is in the foreground.
3. **Microphone (voice):** granted by the in-app prompt on first
   `startListening`; also under Settings → Apps → DJ → Permissions.
4. **Screen capture:** allow it in the system prompt on first `captureScreen`.

## Build

- `minSdk 26`, `targetSdk 35`, applicationId `com.dhanunjay.dj`
  (see `android/app/build.gradle.kts`).
- `MANAGE_EXTERNAL_STORAGE` is deliberately **not** requested — DJ uses SAF +
  its own folders instead.
- Verify: `flutter analyze` then `flutter build apk --debug`.
