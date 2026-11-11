// DJ v3 — app launcher. Open an installed app by name. On Windows
// the app is started by its exe (found on PATH or at a known
// location). Clock, reminder and alarm live on the user's mobile for
// now — those come later, not in v3.

import { execFile, spawn } from 'child_process';
import * as fs from 'fs';
import * as path from 'path';

const APP_PATHS: Record<string, string[]> = {
  notepad: ['notepad.exe'],
  chrome: [
    'chrome.exe',
    'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
  ],
  calculator: ['calc.exe'],
  paint: ['mspaint.exe'],
  word: ['winword.exe'],
  excel: ['excel.exe'],
  powerpoint: ['powerpnt.exe'],
  edge: ['msedge.exe', 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe'],
  'vs code': ['code.exe'],
  code: ['code.exe'],
  spotify: ['spotify.exe'],
  whatsapp: ['whatsapp.exe'],
  explorer: ['explorer.exe'],
  'file explorer': ['explorer.exe'],
  cmd: ['cmd.exe'],
  terminal: ['wt.exe', 'cmd.exe'],
  clock: ['clock.exe'],
};

/** True on Windows (the only platform DJ targets right now). */
export function isWindows(): boolean {
  return process.platform === 'win32';
}

/** Open an installed app by name. Returns {ok, message}. */
export function openApp(name: string): Promise<{ ok: boolean; message: string }> {
  const key = name.trim().toLowerCase();
  return new Promise((resolve) => {
    if (key === 'settings' && isWindows()) {
      execFile('cmd.exe', ['/c', 'start', 'ms-settings:'], (err) => {
        if (err) resolve({ ok: false, message: `I could not open Settings: ${err.message}` });
        else resolve({ ok: true, message: 'Opened Settings.' });
      });
      return;
    }
    const candidates = APP_PATHS[key] ?? [`${key}.exe`];
    const found = candidates.find((c) => {
      if (path.isAbsolute(c)) {
        try {
          return fs.statSync(c).isFile();
        } catch {
          return false;
        }
      }
      return findOnPath(c) !== null;
    });
    if (!found) {
      resolve({
        ok: false,
        message: `I could not find an app called '${name}' on this laptop. Try the full name, like 'Google Chrome', or open it yourself once and tell me.`,
      });
      return;
    }
    const exe = path.isAbsolute(found) ? found : findOnPath(found) ?? found;
    try {
      const child = spawn(exe, [], { detached: true, stdio: 'ignore' });
      child.unref();
      resolve({ ok: true, message: `Opened ${key}.` });
    } catch (err) {
      resolve({ ok: false, message: `I found ${key} but could not open it: ${err}` });
    }
  });
}

function findOnPath(exe: string): string | null {
  const pathExt = process.platform === 'win32' ? (process.env.PATHEXT ?? '.EXE') : '';
  const dirs = (process.env.PATH ?? '').split(path.delimiter);
  for (const dir of dirs) {
    for (const ext of ['', ...pathExt.split(';')]) {
      const cand = path.join(dir, exe + ext);
      try {
        if (fs.statSync(cand).isFile()) return cand;
      } catch {
        // not here
      }
    }
  }
  return null;
}
