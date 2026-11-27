// Windows updates — how DJ updates on Windows.
//
// There is NO auto-updater in the Flutter build. electron-updater has no
// Flutter equivalent, and the two update routes must never fight:
//
// - Direct install (NSIS / zip from GitHub Releases): the user downloads
//   the new installer from the DJ GitHub Releases page
//   (github.com/dhanunjayss0306/dj-laptop-agent) and runs it. The installer
//   replaces the app files only.
// - Microsoft Store build: the Store updates the app itself. DJ must never
//   check for, download, or install its own update in a Store build.
//
// In both cases the data folder is NEVER touched by an update:
// %APPDATA%\DJ\dj_data (dj_config.json, keyword_index.json, vectors.bin,
// vectors_meta.json, MEMORY.md, memory/) survives every update, exactly as
// in the Electron app (PORTING-SPEC.md §1.9).
//
// If a self-update check is ever added, it must reproduce the Electron
// rules: packaged builds only, never in the Store build, never restart the
// app by itself, install on quit, data folder untouched.

/// Short note shown in Settings > About (or wherever update info lives).
const String windowsUpdateNote =
    'Click Check for updates / Update & Restart below to upgrade in-place '
    'automatically without re-extracting zip files. Your settings and index in '
    '%APPDATA%\\DJ\\dj_data are never touched by an update.';
