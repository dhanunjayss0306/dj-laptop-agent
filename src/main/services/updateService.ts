// DJ v3.3 — self-update from GitHub Releases (electron-updater).
//
// How it works, honestly:
//  - Only in the installed app (app.isPackaged). In dev there is no
//    release to check against, so the service stays idle.
//  - On startup (after a short delay, so the window is up first) and
//    once a day while running, it asks GitHub Releases for a newer
//    version of dj-laptop-agent.
//  - When one exists it downloads in the background and tells the UI
//    "Update ready — restart DJ to install". Nothing restarts by
//    itself, and nothing installs while he is using the app: the
//    update is applied when DJ quits (autoInstallOnAppQuit).
//  - If the check fails (no internet, no release yet, GitHub down)
//    the UI gets a plain message and DJ keeps working. No crash, no
//    silent failure.
//  - The FIRST release must exist on GitHub before any of this can
//    work, and every new version still needs a release published
//    (the parent handles that — it needs his token).
//  - His data (index, folders, settings) lives in userData, outside
//    the installed app folder, so an update never touches it.

import type { UpdateState, UpdateStatus } from '../../shared/types';

/** Auto-update only runs in the installed app, never in dev. */
export function shouldEnableAutoUpdate(isPackaged: boolean): boolean {
  return isPackaged;
}

/** Plain text the UI shows for each update state. */
export function updateStatusMessage(status: UpdateStatus, version?: string): string {
  switch (status) {
    case 'idle':
      return '';
    case 'checking':
      return 'Checking for updates…';
    case 'available':
      return version
        ? `DJ ${version} is available — downloading it now.`
        : 'A new DJ version is available — downloading it now.';
    case 'downloading':
      return 'Downloading the DJ update…';
    case 'ready':
      return version
        ? `DJ ${version} is ready — restart DJ to install it.`
        : 'Update ready — restart DJ to install it.';
    case 'up-to-date':
      return 'DJ is up to date.';
    case 'error':
      return 'Could not check for updates — DJ keeps working as-is.';
  }
}

export type UpdaterEvent =
  | 'checking-for-update'
  | 'update-available'
  | 'update-not-available'
  | 'update-downloaded'
  | 'download-progress'
  | 'error';

/**
 * Turn one electron-updater event into the state the UI shows.
 * Returns null for events that are not worth showing (download
 * progress ticks — the "downloading" line already covers them).
 */
export function updateEventToState(
  event: UpdaterEvent,
  info?: { version?: string; message?: string },
): UpdateState | null {
  switch (event) {
    case 'checking-for-update':
      return { status: 'checking', message: updateStatusMessage('checking') };
    case 'update-available':
      return {
        status: 'available',
        message: updateStatusMessage('available', info?.version),
        version: info?.version,
      };
    case 'update-not-available':
      return { status: 'up-to-date', message: updateStatusMessage('up-to-date') };
    case 'update-downloaded':
      return {
        status: 'ready',
        message: updateStatusMessage('ready', info?.version),
        version: info?.version,
      };
    case 'download-progress':
      return { status: 'downloading', message: updateStatusMessage('downloading') };
    case 'error':
      return {
        status: 'error',
        message: info?.message
          ? `Could not check for updates (${info.message}) — DJ keeps working as-is.`
          : updateStatusMessage('error'),
      };
  }
}

const CHECK_DELAY_MS = 15_000;
const CHECK_INTERVAL_MS = 24 * 60 * 60 * 1000;

export class UpdateService {
  private timer: NodeJS.Timeout | null = null;
  private started = false;

  constructor(private readonly onStatus: (s: UpdateState) => void) {}

  /** Start checking (installed app only). Safe to call in dev — no-op. */
  async start(isPackaged: boolean): Promise<void> {
    if (!shouldEnableAutoUpdate(isPackaged) || this.started) return;
    this.started = true;
    // electron-updater is loaded lazily so unit tests can import this
    // module without Electron's updater machinery.
    const { autoUpdater } = await import('electron-updater');
    autoUpdater.autoDownload = true;
    autoUpdater.autoInstallOnAppQuit = true;
    autoUpdater.on('checking-for-update', () => {
      this.emit(updateEventToState('checking-for-update'));
    });
    autoUpdater.on('update-available', (info) => {
      this.emit(updateEventToState('update-available', { version: info.version }));
    });
    autoUpdater.on('update-not-available', () => {
      this.emit(updateEventToState('update-not-available'));
    });
    autoUpdater.on('download-progress', () => {
      this.emit(updateEventToState('download-progress'));
    });
    autoUpdater.on('update-downloaded', (info) => {
      this.emit(updateEventToState('update-downloaded', { version: info.version }));
    });
    autoUpdater.on('error', (err) => {
      this.emit(
        updateEventToState('error', { message: err?.message ?? String(err) }),
      );
    });
    setTimeout(() => void this.check(autoUpdater), CHECK_DELAY_MS);
    this.timer = setInterval(() => void this.check(autoUpdater), CHECK_INTERVAL_MS);
    this.timer.unref?.();
  }

  /** One check, now. A failure is reported, never thrown. */
  async check(autoUpdater?: {
    checkForUpdates(): Promise<unknown>;
  }): Promise<void> {
    try {
      const updater =
        autoUpdater ?? (await import('electron-updater')).autoUpdater;
      await updater.checkForUpdates();
    } catch (err) {
      this.emit(
        updateEventToState('error', {
          message: err instanceof Error ? err.message : String(err),
        }),
      );
    }
  }

  private emit(state: UpdateState | null): void {
    if (state) this.onStatus(state);
  }
}
