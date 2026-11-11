// DJ v3 — file-system paths. One place owns every path DJ uses, so
// no service guesses where things live.

import { app } from 'electron';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';

/** Folder where DJ keeps its index, config and logs (userData). */
export function getDataDir(): string {
  return path.join(app.getPath('userData'), 'dj_data');
}

/** dj_config.json lives next to the app data. */
export function getConfigPath(): string {
  return path.join(getDataDir(), 'dj_config.json');
}

/** The user's home folder. */
export function getHomeDir(): string {
  return os.homedir();
}

/** The real Desktop folder. On this laptop the Desktop is the
 * OneDrive Desktop — the plain Desktop folder does not exist — so
 * check OneDrive first, then the plain Desktop. */
export function findDesktop(home: string): string {
  const oneDrive = path.join(home, 'OneDrive', 'Desktop');
  try {
    if (fs.statSync(oneDrive).isDirectory()) return oneDrive;
  } catch {
    // fall through
  }
  return path.join(home, 'Desktop');
}

/** Default Downloads folder. */
export function getDownloadsDir(home: string): string {
  return path.join(home, 'Downloads');
}
