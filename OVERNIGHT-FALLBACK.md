# DJ v1.2.6 — overnight fix: what changed, and what to do if it still freezes

## What was wrong (root cause, found in the code)
The window opened but stayed blank white and "(Not Responding)" because the
first screen could never be drawn. On startup the app built all 11 pages at
once, and the Duplicates page immediately scanned the whole home folder,
hashing files with a pure-Dart SHA-256 loop that never gave the UI a turn.
The saved search index was also loaded synchronously before the first frame.
So the app was busy, the process ran, but no first frame could ever be
painted. This is fixed in v1.2.6.

## What v1.2.6 changes
- Pages are built lazily: only the Command Center exists at startup; each
  other page builds the first time you open it.
- The duplicate scan yields to the UI regularly, so it can no longer freeze
  the window.
- The saved search index loads after the first frame, not before it.
- The window shows "DJ is starting..." (instead of blank white) until the
  first frame paints, and the window stays responsive (minimize/close work).
- A startup log is written on every launch (see below).
- Plus the bug batch from v1.2.6's base: Privacy Screen settings now persist,
  the capability badge shows the cloud provider, Worker auth + 120 s stream
  timeout + single [DONE], mobile shows 5 bottom tabs, HttpClient leak and
  the 500 ms CPU-stats freeze fixed.

## If v1.2.6 still shows a blank / "Not Responding" window tomorrow
1. Wait 30 seconds. If the "DJ is starting..." label is still there and the
   window does not respond, close it (click the X, or End task on dj.exe in
   Task Manager).
2. Open the folder where you unzipped DJ (next to dj.exe) and find the file
   `dj_startup.log`. Send that file to Muse (or paste its last 30 lines).
   It records every startup step with a time, from both the app and Windows,
   so we can see exactly where it stalls.
3. Do NOT reinstall v1.2.5 or an older version — they have the same freeze.
   The fallback is the backup branch `backup/pre-overnight-2d2d5ae` in the
   repo (the state before this overnight fix), but that version also freezes,
   so it is only a code fallback, not a working app. The real next step is
   the log file in step 2.
4. As a last resort, run DJ from a terminal to see any error: open the DJ
   folder, click the address bar, type `cmd`, press Enter, type `dj.exe`,
   press Enter, and send a screenshot of what it says.

## How to read dj_startup.log (for Muse, not the user)
- `native: first frame rendered` present + `dart: first frame built` present
  = the app started fine; the freeze was the old scan.
- `dart: first frame built` present but no `native: first frame rendered`
  = the stall is on the GPU/renderer side (ANGLE/D3D on this laptop).
- No `dart:` lines past `runApp called` = Dart never ran.
- `WATCHDOG: ... platform thread NOT RESPONDING` = the native Windows
  thread itself is hung.
- If the log points at the renderer, the next step is a test build with
  software rendering forced (needs a runner change, not a setting).

## Version
v1.2.6+6. Backup branch: `backup/pre-overnight-2d2d5ae` (points at 2d2d5ae,
the state before this overnight fix). Nothing here is pushed; pushing needs
the user's GitHub token.
