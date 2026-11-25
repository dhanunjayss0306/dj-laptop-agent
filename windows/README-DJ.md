# DJ — Windows native code (runner + Dart platform channels)

> **Build status: NOT verified on Windows.** This code was written on a
> Linux VM with no Visual Studio and no Windows SDK. No Windows build was
> run here. It was written to be compile-clean by inspection (includes and
> Win32 signatures checked against the Flutter embedder headers in the
> local Flutter SDK), but the Windows builder must compile it with
> `flutter build windows` and fix anything the compiler flags. Do not
> claim it compiles until that build passes.

## What this is

DJ's Dart Core services talk to Windows through six MethodChannels.
The Dart wrappers live in `lib/platform/`; the native implementations
live in `windows/runner/dj_*`. No new pub dependencies, no third-party
native libraries — Win32 APIs only.

| Channel | Dart file | Native files |
|---|---|---|
| `com.dhanunjay.dj/system` | `lib/platform/system_ops_channel.dart` | `dj_system_channel.h/.cpp` |
| `com.dhanunjay.dj/screen` | `lib/platform/screen_channel.dart` | `dj_screen_channel.h/.cpp` |
| `com.dhanunjay.dj/cursor` | `lib/platform/cursor_channel.dart` | `dj_cursor_channel.h/.cpp` |
| `com.dhanunjay.dj/input` | `lib/platform/input_channel.dart` | `dj_input_channel.h/.cpp` |
| `com.dhanunjay.dj/voice` | `lib/platform/voice_channel.dart` | `dj_voice_channel.h/.cpp` |
| `com.dhanunjay.dj/hotkey` | `lib/platform/hotkey_channel.dart` | `dj_hotkey.h/.cpp` |

Shared helpers: `windows/runner/dj_channel_utils.h` (UTF-8/UTF-16
conversion, Win32 error text, `{"ok": true/false, "message": ...}` reply
builders, method-argument readers). Every native method replies with a
Map and never throws across the channel; Dart converts any failure to
`{'ok': false, 'message': ...}`.

## Files added / changed

### Added — Dart (`lib/platform/`)
- `system_ops_channel.dart` — `SystemOpsChannel implements SystemOps`,
  importing the interface from `package:dj/services/system_ops.dart`
  (owned by the Core agent; this file defines no abstract class).
  Typed returns, matching the Core services' usage:
  `openFile` / `openFolder` / `openApp(exe, args)` →
  `({bool ok, String message})`; `deleteToTrash(List<String> paths)` →
  `Future<void>` (one Recycle Bin call for the whole list; throws a
  `PlatformException` on native failure, which the callers catch);
  `getSystemStats()` → `SystemStats` (built with
  `SystemStats.fromJson`); `setStartAtLogin(bool)` → `Future<bool>`
  (the value now in effect); `getHomeDir()` → `String`, synchronous by
  interface design (cached native value, warmed at construction,
  falling back to `USERPROFILE`); `pickFolder()` → `Future<String?>`
  (null on cancel). Extra, not on the interface: `getDownloadsDir()` →
  `Future<String?>` via the native channel. Also receives the native
  `onTrayHidden` call (see `onTrayHidden` callback; Dart owns the
  show-once flag in `dj_config.json`).
- `screen_channel.dart` — `captureScreen()` → `ScreenCapture` (PNG bytes,
  width/height, monitor list). Null on failure, never throws.
- `cursor_channel.dart` — `showCursor(x, y, [label])`,
  `moveCursor(x, y, [label])`, `hideCursor()`, plus `annotate(annotations)`
  and `clearAnnotations()` (see Screen annotations below). Bool results,
  never throws.
- `hotkey_channel.dart` — `registerHotkey({ctrl, alt, shift, win, vk})`,
  `unregisterHotkey()`, and a `Stream<void> onHotkeyPressed` fed by the
  native `onHotkeyPressed` call. Bool results, never throws.
- `input_channel.dart` — `moveMouse(x, y)`, `click([button])`,
  `typeText(text)`, `pressKey(key)`. Bool results, never throws.
- `voice_channel.dart` — `speak(text)`, `stopSpeak()`,
  `startWhisper(modelPath)`, `transcribe(audioPath)`,
  `whisperStatus([modelPath])`. Map results, never throws.
- `update_note.dart` — no auto-updater by design; documents that Windows
  updates come from GitHub Releases (direct install) or the Microsoft
  Store (Store build), and that `%APPDATA%\DJ\dj_data` is never touched
  by an update.

### Added — C++ (`windows/runner/`)
- `dj_channel_utils.h` — shared helpers (see above).
- `dj_system_channel.h/.cpp` — system channel.
- `dj_screen_channel.h/.cpp` — screen capture.
- `dj_cursor_channel.h/.cpp` — fake cursor overlay window, plus screen
  annotations drawn on the same window.
- `dj_hotkey.h/.cpp` — global hotkey (`RegisterHotKey` on the runner
  window, `WM_HOTKEY` routed from `FlutterWindow::MessageHandler`).
- `dj_input_channel.h/.cpp` — SendInput.
- `dj_voice_channel.h/.cpp` — SAPI TTS + whisper.cpp sidecar hook.
- `dj_tray.h/.cpp` — system tray.

### Changed
- `windows/runner/flutter_window.h/.cpp` — creates the six channels in
  `OnCreate`, destroys tray then hotkey then the other channels then the
  Flutter controller in `OnDestroy`; intercepts `WM_CLOSE` (hide to tray
  while the tray exists); routes tray messages and `WM_HOTKEY` (hotkey
  channel); new `ShowWindow()` (restore + show + focus) used by the
  tray's "Open DJ" / icon click.
- `windows/runner/main.cpp` — window is now 880 x 720 titled
  `DJ — your files, found` (PORTING-SPEC.md §0). `SetQuitOnClose(true)`
  stays: with a tray, `WM_CLOSE` is intercepted so quit only happens via
  "Quit DJ"; without a tray, close quits.
- `windows/runner/CMakeLists.txt` — the seven new `.cpp` files, plus link
  libraries `shell32.lib`, `ole32.lib`, `sapi.lib`, `winhttp.lib`,
  `gdiplus.lib`. (`RegisterHotKey` needs no extra library: it is in
  `user32.lib`, which the runner already links.)

## Win32 APIs used

### System (`dj_system_channel.cpp`)
- `openFile` / `openFolder`: `ShellExecuteW(NULL, L"open", path, ...)`.
  Success is a return value > 32.
- `openApp`: `CreateProcessW` with `DETACHED_PROCESS |
  CREATE_NEW_PROCESS_GROUP`, command line built as quoted exe + quoted
  args (paths with spaces work). No console window.
- `deleteToTrash`: `SHFileOperationW`, `FO_DELETE` +
  `FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT`, over a
  double-null-terminated list built from the `paths` array (one call for
  the whole list, like Electron's single `trash()` call; a single `path`
  string is also accepted). Paths already gone are skipped and reported
  in the message. **Recycle Bin only — there is no permanent delete.**
- `getSystemStats`: `GetSystemInfo` (cores), `GlobalMemoryStatusEx`
  (total/free RAM), `GetTickCount64` (uptime), `GetSystemTimes` two
  samples 500 ms apart for CPU% (same approach as Electron's two
  `os.cpus()` samples). CPU is `null` when unmeasurable — never invented.
  No disk usage, same as Electron.
- `setStartAtLogin`: `RegOpenKeyExW` + `RegSetValueExW` /
  `RegDeleteValueW` on
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, value name `DJ`,
  data = this exe's full path (`GetModuleFileNameW`).
- `getHomeDir`: `SHGetKnownFolderPath(FOLDERID_Profile)`.
- `getDownloadsDir`: `SHGetKnownFolderPath(FOLDERID_Downloads)`.
- `pickFolder`: `IFileDialog` (`CoCreateInstance(CLSID_FileOpenDialog)`)
  with `FOS_PICKFOLDERS`; cancel returns
  `{'ok': false, 'message': 'cancelled', 'path': null}`.

### Screen (`dj_screen_channel.cpp`)
- Virtual desktop bounds: `GetSystemMetrics(SM_XVIRTUALSCREEN /
  SM_YVIRTUALSCREEN / SM_CXVIRTUALSCREEN / SM_CYVIRTUALSCREEN)`.
- Capture: `GetDC(NULL)`, `CreateCompatibleDC`,
  `CreateCompatibleBitmap`, `BitBlt(..., SRCCOPY)`.
- PNG encode: GDI+ (`GdiplusStartup`, `Gdiplus::Bitmap`,
  `GetImageEncoders` for the `image/png` CLSID, `CreateStreamOnHGlobal`).
- Monitors: `EnumDisplayMonitors` + `GetMonitorInfoW`
  (`MONITORINFOF_PRIMARY` marks the primary). The PNG covers the whole
  virtual desktop; the `monitors` list gives each monitor's bounds.

### Cursor overlay (`dj_cursor_channel.cpp`)
- Layered window: `CreateWindowExW(WS_EX_LAYERED | WS_EX_TRANSPARENT |
  WS_EX_TOPMOST | WS_EX_TOOLWINDOW, ..., WS_POPUP)`. `WS_EX_TRANSPARENT`
  means it never intercepts clicks; `WS_EX_TOOLWINDOW` means no taskbar
  icon. Never moves the real mouse.
- Drawing: 32-bit top-down DIB (`CreateDIBSection`), GDI triangle +
  label bubble in DJ blue `#0071E3`, `UpdateLayeredWindow` with
  `ULW_ALPHA`. Pixels GDI painted become opaque; untouched pixels stay
  transparent.
- Animation: `SetTimer` at ~16 ms, ease-out cubic slide over 300 ms from
  the old position to the new one (`SetWindowPos`, `SWP_NOACTIVATE`).
  The triangle tip sits exactly at the requested (x, y).

### Screen annotations (`dj_cursor_channel.cpp`, `annotate` /
`clearAnnotations`)
- Same layered overlay window as the cursor, same DJ blue `#0071E3`,
  still `WS_EX_TRANSPARENT` (click-through) and on top of everything.
  While annotations are shown the window is resized to cover the whole
  virtual screen (`SM_XVIRTUALSCREEN` / `SM_YVIRTUALSCREEN` /
  `SM_CXVIRTUALSCREEN` / `SM_CYVIRTUALSCREEN`), so annotations can sit
  anywhere; the cursor triangle is drawn inside it at its position and
  `moveCursor` jumps instead of sliding (the window itself never moves).
  Clearing shrinks the window back to the small cursor window.
- Shapes (one map each in the `annotations` list; unknown types and
  malformed entries are skipped, never an error for the whole call):
  `circle {type, x, y, r}` — 3 px blue outline (`Ellipse`,
  `NULL_BRUSH`); `arrow {type, x1, y1, x2, y2}` — 3 px blue line plus a
  filled arrowhead (~25° spread, 18 px long); `rect {type, x, y, w, h}`
  — 3 px solid blue border plus a translucent blue fill (~27% opaque,
  painted straight into the DIB pixels after the GDI pass, because GDI
  cannot paint translucently); `text {type, x, y, text}` — small blue
  label bubble with white text (same style as the cursor label, 18 pt
  Segoe UI).
- `annotate(list)` replaces the current annotations and shows them even
  when the cursor is hidden; an empty list clears. They persist until
  `clearAnnotations()` or `hideCursor()` (hiding the cursor also clears
  them). Each `annotate`/`clearAnnotations` redraws the whole overlay
  from a fresh full-virtual-screen DIB, so a very large multi-monitor
  desktop costs one large DIB per draw.

### Global hotkey (`dj_hotkey.cpp`)
- `registerHotkey(modifiers, vk)`: `RegisterHotKey` on the runner
  window (id 1, one hotkey at a time; a new registration replaces the
  old one). `modifiers` is a list of strings — `'ctrl'`/`'control'`,
  `'alt'`, `'shift'`, `'win'`/`'windows'` (case-insensitive) — mapped to
  `MOD_CONTROL` / `MOD_ALT` / `MOD_SHIFT` / `MOD_WIN`, plus
  `MOD_NOREPEAT` so holding the keys down fires one event, not repeats.
  `vk` is a Windows virtual-key code int (1–255). Default hotkey is
  **Ctrl+Alt+D** (`['ctrl', 'alt']`, vk `0x44` = `'D'`), set by the Dart
  wrapper's defaults (`HotkeyChannel.registerHotkey` / `defaultVk`);
  the native side keeps no default of its own and registers nothing
  until Dart asks.
- `WM_HOTKEY` arrives on the runner window even when DJ is not focused
  (that is what makes it global). `FlutterWindow::MessageHandler`
  routes it to `DjHotkeyChannel::HandleMessage` (same pattern as the
  tray messages), which invokes the Dart method `onHotkeyPressed` on
  the channel (same `InvokeMethod` pattern as
  `DjSystemChannel::NotifyTrayHidden`); Dart exposes it as
  `HotkeyChannel.onHotkeyPressed` and decides what the press does
  (default idea: show/focus the DJ window).
- Failure: if the hotkey is already taken by another app
  (`ERROR_HOTKEY_ALREADY_REGISTERED`) the reply is exactly
  `{'ok': false, 'message': 'hotkey already in use — pick another'}`;
  other failures report the Win32 error text. DJ never steals another
  app's hotkey and never crashes on failure.
- `unregisterHotkey()` unregisters (a no-op success when nothing is
  registered). The hotkey is also unregistered when the channel is
  destroyed (window destroy, `OnDestroy` destroys the hotkey channel
  first).

### Input (`dj_input_channel.cpp`)
- `SendInput` throughout. `moveMouse`: `MOUSEEVENTF_MOVE |
  MOUSEEVENTF_ABSOLUTE`, coordinates normalized to 0–65535 over the
  virtual screen (`SM_XVIRTUALSCREEN` etc.). `click`:
  `MOUSEEVENTF_LEFTDOWN/UP`, `RIGHTDOWN/UP`, `MIDDLEDOWN/UP`.
  `typeText`: `KEYBDINPUT` with `KEYEVENTF_UNICODE` (down + up per UTF-16
  unit; astral characters go as surrogate pairs, which is correct).
  `pressKey`: named keys via a map (see below) or a single character via
  `VkKeyScanW`; modifiers pressed first, released last in reverse order.
- **Safety lives in Dart, not here.** This file does exactly what Dart
  asks: no step limit, no stuck detection, no show-before-click, no
  foreground-window checks. The Dart caller must show the fake cursor
  first, cap automated steps, and keep input away from password prompts
  and password managers. (Also stated in `lib/platform/input_channel.dart`.)

`pressKey` names (case-insensitive, `+` joins modifiers):
`Enter`, `Return`, `Escape`, `Esc`, `Tab`, `Space`, `Backspace`, `Delete`,
`Insert`, `Home`, `End`, `PageUp`, `PageDown`, `Up`, `Down`, `Left`,
`Right`, `F1`–`F12`, `Win`, `Menu`, `PrintScreen`, `CapsLock`, `NumLock`,
`ScrollLock`, any single character (e.g. `a`, `1`), and combos such as
`Alt+Tab`, `Ctrl+C`, `Ctrl+V`, `Ctrl+Shift+Esc`, `Win+D`, `Shift+F10`.
Modifiers: `Ctrl`/`Control`, `Alt`, `Shift`, `Win`/`Windows`. A lone
modifier (`Win`) taps it.

### Voice (`dj_voice_channel.cpp`)
- TTS: SAPI `ISpVoice` (`CoCreateInstance(CLSID_SpVoice)`), `Speak` with
  `SPF_ASYNC | SPF_IS_NOT_XML`. One persistent voice per channel, so
  `stopSpeak` (empty text + `SPF_PURGEBEFORESPEAK`) stops what `speak`
  started. Works offline, no downloads. Requires COM initialized
  (`main.cpp` does `CoInitializeEx` at startup).
- Whisper sidecar: `startWhisper(modelPath)` looks for
  `<exe dir>\whisper-server.exe`, then `<exe dir>\whisper\whisper-server.exe`.
  Missing binary or model →
  `{'ok': false, 'message': 'whisper not installed — see WINDOWS-BUILD.md'}`.
  Found → `CreateProcessW(..., CREATE_NO_WINDOW)` with
  `--model <path> --host 127.0.0.1 --port 8080` (localhost only).
  The process is terminated when DJ quits. `transcribe(audioPath)` POSTs
  the file as `multipart/form-data` field `file` to
  `http://127.0.0.1:8080/inference` via WinHttp
  (`WinHttpOpen/Connect/OpenRequest/SendRequest/ReceiveResponse/ReadData`)
  and extracts the `"text"` field from the JSON reply with a minimal
  parser (handles `\" \\ \/ \n \r \t \uXXXX`). No transcript is ever
  invented: a missing sidecar, a dead server, or a reply without text is
  a plain `ok: false`.

### Tray (`dj_tray.cpp`)
- `Shell_NotifyIconW` (`NIM_ADD` / `NIM_DELETE`), tooltip
  `DJ - your files, found`. Icon file candidates:
  `<exe dir>\tray-icon.ico`, then `<exe dir>\resources\tray-icon.ico`.
  **Ship `tray-icon.ico` next to `dj.exe` (or under `resources/`) or
  there is no tray** — same rule as Electron. (The repo's
  `windows/runner/resources/app_icon.ico` is the app icon; copy it as
  `tray-icon.ico` into the install folder if no separate tray icon is made.)
- Left-click = Open DJ. Right-click = menu with exactly `Open DJ` then
  `Quit DJ` (`TrackPopupMenu`, with the standard `SetForegroundWindow` +
  `PostMessage(WM_NULL)` pattern so the menu dismisses correctly).

## Start-at-login

Via the Run registry key (same as `setStartAtLogin` above). The Dart side
owns the default (ON when installed, OFF in dev, per PORTING-SPEC §1.8)
and the Settings toggle; the native side only reads/writes the key.

## Updates

No auto-updater (see `lib/platform/update_note.dart`). Direct installs
update from GitHub Releases by the user running the new installer; Store
builds update through the Store. The data folder
`%APPDATA%\DJ\dj_data` is never touched by an update.

## What the Windows builder must verify

1. `flutter build windows` compiles clean — especially the embedder API
   use (`engine->messenger()`, `MethodChannel<EncodableValue>`,
   `SetMethodCallHandler`, `InvokeMethod`) and the SAPI/WinHttp/GDI+
   includes and link libraries.
2. Each channel answers from the Dart side (open a file/folder/app,
   Recycle Bin delete restores from the Bin, stats show real numbers,
   folder picker returns a path / cancel).
3. Screenshot PNG opens and matches the screen; monitor bounds are right
   on multi-monitor setups.
4. Fake cursor: visible marker, smooth slide, clicks pass through it,
   real mouse never moves.
5. Real input: mouse moves/clicks, typing produces the exact text
   (including non-ASCII), `Alt+Tab` switches windows.
6. TTS speaks offline; `stopSpeak` stops it mid-sentence.
7. Whisper: with `whisper-server.exe` + a ggml model next to the exe,
   `transcribe` returns real text; without them, `startWhisper` returns
   the not-installed message and nothing crashes.
8. Tray: with `tray-icon.ico` present, close hides, click reopens,
   `Quit DJ` quits, first-hide note fires once (Dart flag). Without the
   icon file, close quits.
9. Start-at-login toggle writes/removes the `DJ` value under the Run key
   (check with `reg query HKCU\...\Run`).
10. Global hotkey: with DJ unfocused (another app in front), Ctrl+Alt+D
    fires `onHotkeyPressed` in Dart; pressing it while another app holds
    the same hotkey returns the 'already in use' message and registers
    nothing; quitting DJ releases the hotkey (another app can then take
    it).
11. Annotations: `annotate` draws a circle, an arrow, a highlight rect
    and a text label at the right screen spots, all click-through
    (clicks pass to the app underneath); the cursor triangle still shows
    and moves; `clearAnnotations` removes only the annotations;
    `hideCursor` removes annotations too.
