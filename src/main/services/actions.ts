// DJ v3 — small actions that open things on the laptop. Kept
// separate from the chat service so they are easy to test and to
// swap per platform.

import { execFile } from 'child_process';
import { shell } from 'electron';

/** Open a file with the app Windows (or the OS) chose for it. */
export function openFile(filePath: string): Promise<{ ok: boolean; message: string }> {
  return new Promise((resolve) => {
    if (process.platform === 'win32') {
      execFile('cmd.exe', ['/c', 'start', '', filePath], (err) => {
        if (err) resolve({ ok: false, message: `I could not open that file: ${err.message}` });
        else resolve({ ok: true, message: `Opened ${filePath}.` });
      });
    } else {
      execFile('xdg-open', [filePath], (err) => {
        if (err) resolve({ ok: false, message: `I could not open that file: ${err.message}` });
        else resolve({ ok: true, message: `Opened ${filePath}.` });
      });
    }
  });
}

/** Open a folder in the file manager (Explorer on Windows). */
export async function openFolder(folderPath: string): Promise<{ ok: boolean; message: string }> {
  try {
    const error = await shell.openPath(folderPath);
    if (error) return { ok: false, message: `I could not open that folder: ${error}` };
    return { ok: true, message: `Opened ${folderPath}.` };
  } catch (err) {
    return { ok: false, message: `I could not open that folder: ${String(err)}` };
  }
}
