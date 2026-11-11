// DJ v3.2 — file-type helpers. Pure functions, no React, no DOM:
// which Explorer-style icon a file gets, and how its size and date
// are shown. Used by FileRow and tested in tests/fileTypes.test.ts.

export type FileKind =
  | 'word'
  | 'pdf'
  | 'image'
  | 'video'
  | 'audio'
  | 'folder'
  | 'sheet'
  | 'archive'
  | 'code'
  | 'text'
  | 'file';

const WORD_EXTS = new Set(['.doc', '.docx']);
const PDF_EXTS = new Set(['.pdf']);
const IMAGE_EXTS = new Set(['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.svg', '.ico']);
const VIDEO_EXTS = new Set(['.mp4', '.mov', '.avi', '.mkv', '.webm', '.wmv']);
const AUDIO_EXTS = new Set(['.mp3', '.wav', '.ogg', '.flac', '.m4a']);
const SHEET_EXTS = new Set(['.xls', '.xlsx', '.ods']);
const ARCHIVE_EXTS = new Set(['.zip', '.rar', '.7z', '.tar', '.gz']);
const CODE_EXTS = new Set([
  '.js', '.ts', '.jsx', '.tsx', '.py', '.java', '.c', '.cpp', '.h',
  '.html', '.css', '.json', '.xml', '.sql', '.sh',
]);
const TEXT_EXTS = new Set(['.txt', '.md', '.csv', '.log', '.rtf']);

/** Which icon a file gets, from its name alone. Case-insensitive;
 *  an unknown or missing extension is a plain file. */
export function getFileKind(fileName: string): FileKind {
  const name = (fileName || '').trim();
  const dot = name.lastIndexOf('.');
  if (dot <= 0) return 'file';
  const ext = name.slice(dot).toLowerCase();
  if (WORD_EXTS.has(ext)) return 'word';
  if (PDF_EXTS.has(ext)) return 'pdf';
  if (IMAGE_EXTS.has(ext)) return 'image';
  if (VIDEO_EXTS.has(ext)) return 'video';
  if (AUDIO_EXTS.has(ext)) return 'audio';
  if (SHEET_EXTS.has(ext)) return 'sheet';
  if (ARCHIVE_EXTS.has(ext)) return 'archive';
  if (CODE_EXTS.has(ext)) return 'code';
  if (TEXT_EXTS.has(ext)) return 'text';
  return 'file';
}

/** "1532860" bytes -> "1.5 MB". Explorer-style, one decimal. */
export function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return '';
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}

/** An ISO date ("2026-11-12T00:00:00.000Z") -> "12 Nov 2026".
 *  An empty or invalid date shows nothing. */
export function formatDate(iso: string): string {
  if (!iso) return '';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  return d.toLocaleDateString('en-GB', {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
  });
}
