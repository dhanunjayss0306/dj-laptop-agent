// DJ v3 — file reader. Reads the text out of a file. Returns ""
// when it cannot be read. Never writes into a file — DJ is
// information-giving only.
//
// PDF and DOCX libraries are loaded lazily, so a broken library
// never stops the app from starting (they are only needed when such
// a file is read).

import * as fs from 'fs';
import * as path from 'path';

// eslint-disable-next-line @typescript-eslint/no-explicit-any
let pdfParse: any = null;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
let mammoth: any = null;

/** Read the text out of a file (async: PDF/DOCX parsing is async). */
export async function readText(filePath: string): Promise<string> {
  const suffix = path.extname(filePath).toLowerCase();
  try {
    if (suffix === '.pdf') {
      if (!pdfParse) {
        // eslint-disable-next-line @typescript-eslint/no-require-imports
        pdfParse = require('pdf-parse');
      }
      const data = await pdfParse(fs.readFileSync(filePath));
      return typeof data?.text === 'string' ? data.text : '';
    }
    if (suffix === '.docx') {
      if (!mammoth) {
        // eslint-disable-next-line @typescript-eslint/no-require-imports
        mammoth = require('mammoth');
      }
      const result = await mammoth.extractRawText({ path: filePath });
      return typeof result?.value === 'string' ? result.value : '';
    }
    // Plain text files (code, notes, markdown, csv, ...).
    try {
      return fs.readFileSync(filePath, 'utf-8');
    } catch {
      return fs.readFileSync(filePath, 'latin1');
    }
  } catch {
    return '';
  }
}
