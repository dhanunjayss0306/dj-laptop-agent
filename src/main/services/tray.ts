// DJ v5.6 — always-running app: system tray + start at login.
// The pure decisions live here so tests can prove them without
// Electron; the thin createTray() wrapper is the only part that
// touches the real Tray class.

import * as fs from 'fs';
import * as path from 'path';
import { Menu, Tray, type BrowserWindow } from 'electron';

/** Effective "start at login" when the config has no saved choice:
 *  on in the packaged app, off in dev. */
export function resolveStartAtLogin(
  saved: boolean | undefined,
  isPackaged: boolean,
): boolean {
  return saved ?? isPackaged;
}

/** The exact settings handed to Electron. Only openAtLogin: for an
 *  installed NSIS app Electron uses the app's own exe path. */
export function buildLoginItemSettings(enabled: boolean): {
  openAtLogin: boolean;
} {
  return { openAtLogin: enabled };
}

/** What closing the window does. With a tray it hides; without a
 *  tray (or while really quitting) it quits. */
export function decideCloseAction(opts: {
  hasTray: boolean;
  isQuitting: boolean;
}): 'hide' | 'quit' {
  if (opts.isQuitting) return 'quit';
  return opts.hasTray ? 'hide' : 'quit';
}

/** Tray menu items, in order. 'open' shows the window, 'quit'
 *  really quits the app. */
export const TRAY_MENU = [
  { id: 'open', label: 'Open DJ' },
  { id: 'quit', label: 'Quit DJ' },
] as const;

export type TrayActionId = (typeof TRAY_MENU)[number]['id'];

/** The action for a menu item id, or null for an unknown id. */
export function trayActionFor(id: string): TrayActionId | null {
  return TRAY_MENU.some((item) => item.id === id) ? (id as TrayActionId) : null;
}

/** First existing path from the candidates, or null when none
 *  exists. Packaged builds try resources/tray-icon.ico first;
 *  dev falls back to assets/icon.ico in the repo. */
export function pickExistingIcon(candidates: string[]): string | null {
  for (const candidate of candidates) {
    try {
      if (fs.existsSync(candidate)) return candidate;
    } catch {
      // Unreadable path: try the next candidate.
    }
  }
  return null;
}

/** Tray icon candidates, packaged path first. */
export function trayIconCandidates(
  resourcesPath: string,
  appPath: string,
): string[] {
  return [
    path.join(resourcesPath, 'tray-icon.ico'),
    path.join(appPath, 'assets', 'icon.ico'),
  ];
}

export interface TrayCallbacks {
  /** Show and focus the window (create it first if it is gone). */
  onOpen: () => void;
  /** Really quit the app. */
  onQuit: () => void;
}

/** Create the tray icon. Returns null when the icon file is
 *  missing or Tray creation throws — the app then falls back to
 *  the old behaviour (closing the window quits). */
export function createTray(
  iconPath: string,
  callbacks: TrayCallbacks,
): Tray | null {
  let tray: Tray;
  try {
    tray = new Tray(iconPath);
  } catch {
    return null;
  }
  tray.setToolTip('DJ - your files, found');
  tray.setContextMenu(
    Menu.buildFromTemplate(
      TRAY_MENU.map((item) => ({
        label: item.label,
        click: () => {
          if (item.id === 'open') callbacks.onOpen();
          else callbacks.onQuit();
        },
      })),
    ),
  );
  // A plain click on the icon opens the window again.
  tray.on('click', () => callbacks.onOpen());
  return tray;
}

/** Show a window that may be hidden, and focus it. */
export function showWindow(win: BrowserWindow): void {
  if (win.isMinimized()) win.restore();
  win.show();
  win.focus();
}
