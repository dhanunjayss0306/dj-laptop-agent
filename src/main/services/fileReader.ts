// DJ v5.5 — file reader. Reads the text out of a file and says
// HONESTLY what it found. Returns "" when it cannot be read. Never
// writes into a file — DJ is information-giving only.
//
// PDF and DOCX/Office libraries are loaded lazily, so a broken
// library never stops the app from starting (they are only needed
// when such a file is read).
//
// What it covers, and what it honestly cannot do:
//   .txt/.md/code/.csv/.json/.log — plain text (UTF-8, latin1 fallback).
//   .pdf — pdf-parse. Page-aware: form feeds mark page breaks.
//     A PDF with pages but zero extractable text is a scanned-image
//     PDF — reported as 'no-text', never silently empty. A locked /
//     encrypted PDF is reported as 'encrypted'.
//   .docx — mammoth (raw text).
//   .pptx/.xlsx — jszip + small XML pulls (slide text runs, shared
//     strings + cell values). Best-effort text for search, NOT a
//     full Office parser: no slide notes, no formatting, no formulas
//     beyond their stored result, no charts.
//   .doc/.ppt/.xls (old binary Office) — NOT supported: they need a
//     heavy binary parser DJ does not ship. They are skipped plainly.

import * as fs from 'fs';
import * as path from 'path';

// eslint-disable-next-line @typescript-eslint/no-explicit-any
let pdfParse: any = null;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
let mammoth: any = null;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
let JSZip: any = null;

/** What a read found. 'ok' means text was extracted. */
export type ReadStatus = 'ok' | 'no-text' | 'encrypted' | 'unreadable';

export interface FileContent {
  text: string;
  status: ReadStatus;
  /** Page count, when the format reports one (PDF). */
  pages?: number;
}

/** Most text DJ keeps from one PDF (a 300-page manual is not
 *  usefully embedded in full; the first 200,000 chars cover it). */
export const PDF_TEXT_LIMIT = 200_000;

/**
 * One page of PDF text, rendered the way pdf-parse's own default
 * does (text items joined, a newline when the line's Y changes),
 * plus a form feed at the end of every page. The form feed is
 * what chunkPdfText splits on — without it, pdf-parse's output
 * has no page marks at all (verified: a real PDF's text contains
 * no '\f'), and page-aware chunking never fires.
 */
async function renderPageWithBreak(pageData: {
  getTextContent: (opts: { normalizeWhitespace: boolean; disableCombineTextItems: boolean }) => Promise<{ items: { str: string; transform: number[] }[] }>;
}): Promise<string> {
  const textContent = await pageData.getTextContent({
    normalizeWhitespace: false,
    disableCombineTextItems: false,
  });
  let lastY: number | undefined;
  let text = '';
  for (const item of textContent.items) {
    if (lastY === item.transform[5] || lastY === undefined) {
      text += item.str;
    } else {
      text += '\n' + item.str;
    }
    lastY = item.transform[5];
  }
  return text + '\f';
}

/** How much of a file the binary sniff looks at (first bytes). */
const SNIFF_BYTES = 512;

function decodeXmlEntities(s: string): string {
  return s
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&');
}

/** Text runs (<a:t>…</a:t>) out of one slide's XML. */
function slideText(xml: string): string {
  const runs: string[] = [];
  const re = /<a:t>([\s\S]*?)<\/a:t>/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(xml)) !== null) {
    runs.push(decodeXmlEntities(m[1]));
  }
  return runs.join(' ');
}

function loadJSZip(): void {
  if (!JSZip) {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    JSZip = require('jszip');
  }
}

/** Best-effort text out of a .pptx buffer (slide text runs only). */
async function readPptx(buf: Buffer): Promise<FileContent> {
  loadJSZip();
  const zip = await JSZip.loadAsync(buf);
  const slideNames = Object.keys(zip.files)
    .filter((n) => /^ppt\/slides\/slide\d+\.xml$/.test(n))
    .sort((a, b) => {
      const na = parseInt(a.match(/slide(\d+)\.xml$/)?.[1] ?? '0', 10);
      const nb = parseInt(b.match(/slide(\d+)\.xml$/)?.[1] ?? '0', 10);
      return na - nb;
    });
  const parts: string[] = [];
  for (const name of slideNames) {
    const xml = await zip.files[name].async('string');
    const t = slideText(xml);
    if (t.trim()) parts.push(t);
  }
  const text = parts.join('\n');
  return text.trim()
    ? { text, status: 'ok' }
    : { text: '', status: 'no-text' };
}

/** Best-effort text out of a .xlsx buffer (shared strings + cells). */
async function readXlsx(buf: Buffer): Promise<FileContent> {
  loadJSZip();
  const zip = await JSZip.loadAsync(buf);
  // Shared string table, in order — cells refer to it by index.
  let shared: string[] = [];
  const sharedFile = zip.files['xl/sharedStrings.xml'];
  if (sharedFile) {
    const xml = await sharedFile.async('string');
    const re = /<t[^>]*>([\s\S]*?)<\/t>/g;
    let m: RegExpExecArray | null;
    while ((m = re.exec(xml)) !== null) {
      shared.push(decodeXmlEntities(m[1]));
    }
  }
  const sheetNames = Object.keys(zip.files)
    .filter((n) => /^xl\/worksheets\/sheet\d+\.xml$/.test(n))
    .sort();
  const rows: string[] = [];
  for (const name of sheetNames) {
    const xml = await zip.files[name].async('string');
    // One <row> at a time, so a sheet reads row by row.
    const rowRe = /<row[\s>][\s\S]*?<\/row>|<row[\s>][\s\S]*?\/>/g;
    let rowMatch: RegExpExecArray | null;
    while ((rowMatch = rowRe.exec(xml)) !== null) {
      const rowXml = rowMatch[0];
      const cells: string[] = [];
      const cellRe = /<c(\s[^>]*)?>([\s\S]*?)<\/c>|<c(\s[^>]*)?\/>/g;
      let cellMatch: RegExpExecArray | null;
      while ((cellMatch = cellRe.exec(rowXml)) !== null) {
        const attrs = cellMatch[1] ?? cellMatch[3] ?? '';
        const inner = cellMatch[2] ?? '';
        const typeMatch = attrs.match(/\bt="([^"]+)"/);
        const type = typeMatch ? typeMatch[1] : '';
        if (type === 's') {
          const v = inner.match(/<v>(\d+)<\/v>/);
          if (v && shared[parseInt(v[1], 10)] !== undefined) {
            cells.push(shared[parseInt(v[1], 10)]);
          }
        } else if (type === 'inlineStr') {
          const t = inner.match(/<t[^>]*>([\s\S]*?)<\/t>/);
          if (t) cells.push(decodeXmlEntities(t[1]));
        } else {
          // Number, boolean, date, or a formula's stored result.
          const v = inner.match(/<v>([\s\S]*?)<\/v>/);
          if (v) cells.push(v[1]);
        }
      }
      if (cells.length > 0) rows.push(cells.join(' '));
    }
  }
  const text = rows.join('\n');
  return text.trim()
    ? { text, status: 'ok' }
    : { text: '', status: 'no-text' };
}

/**
 * Quick binary sniff: a text file never contains a NUL byte in
 * its first bytes; a binary file mislabelled .txt almost always
 * does. Cheap — reads 512 bytes, never the whole file.
 */
export function isProbablyBinary(filePath: string): boolean {
  try {
    const fd = fs.openSync(filePath, 'r');
    try {
      const buf = Buffer.alloc(SNIFF_BYTES);
      const read = fs.readSync(fd, buf, 0, SNIFF_BYTES, 0);
      for (let i = 0; i < read; i++) {
        if (buf[i] === 0) return true;
      }
      return false;
    } finally {
      fs.closeSync(fd);
    }
  } catch {
    return false;
  }
}

/** Read the text out of a file, with an honest status. */
export async function readFileContent(filePath: string): Promise<FileContent> {
  const suffix = path.extname(filePath).toLowerCase();
  try {
    if (suffix === '.pdf') {
      if (!pdfParse) {
        // Lazy dynamic import (not require): a broken PDF library
        // must never stop the app from starting, and dynamic
        // import is also what test mocks can intercept.
        const mod = await import('pdf-parse');
        pdfParse = mod.default;
      }
      let data: { text?: string; numpages?: number };
      try {
        // Custom pagerender: same text as pdf-parse's default,
        // plus a form feed after each page (see renderPageWithBreak).
        data = await pdfParse(fs.readFileSync(filePath), {
          pagerender: renderPageWithBreak,
        });
      } catch (err) {
        const msg = String((err as Error)?.message ?? err).toLowerCase();
        if (msg.includes('encrypt') || msg.includes('password')) {
          return { text: '', status: 'encrypted' };
        }
        return { text: '', status: 'unreadable' };
      }
      const raw = typeof data?.text === 'string' ? data.text : '';
      const pages = typeof data?.numpages === 'number' ? data.numpages : undefined;
      if (raw.trim().length === 0) {
        // Pages exist but no text came out: a scanned-image PDF
        // (or a blank one). Say so, instead of silently nothing.
        return { text: '', status: 'no-text', pages };
      }
      return {
        text: raw.slice(0, PDF_TEXT_LIMIT),
        status: 'ok',
        pages,
      };
    }
    if (suffix === '.docx') {
      if (!mammoth) {
        // eslint-disable-next-line @typescript-eslint/no-require-imports
        mammoth = require('mammoth');
      }
      const result = await mammoth.extractRawText({ path: filePath });
      const text = typeof result?.value === 'string' ? result.value : '';
      return text.trim()
        ? { text, status: 'ok' }
        : { text: '', status: 'no-text' };
    }
    if (suffix === '.pptx') {
      try {
        return await readPptx(fs.readFileSync(filePath));
      } catch {
        return { text: '', status: 'unreadable' };
      }
    }
    if (suffix === '.xlsx') {
      try {
        return await readXlsx(fs.readFileSync(filePath));
      } catch {
        return { text: '', status: 'unreadable' };
      }
    }
    // Plain text files (code, notes, markdown, csv, ...).
    if (isProbablyBinary(filePath)) {
      return { text: '', status: 'unreadable' };
    }
    try {
      return { text: fs.readFileSync(filePath, 'utf-8'), status: 'ok' };
    } catch {
      return { text: fs.readFileSync(filePath, 'latin1'), status: 'ok' };
    }
  } catch {
    return { text: '', status: 'unreadable' };
  }
}

/** Read the text out of a file (async: PDF/DOCX parsing is async).
 *  Kept for callers that only need the text (summaries). */
export async function readText(filePath: string): Promise<string> {
  const content = await readFileContent(filePath);
  return content.text;
}
