// DJ v3.2 — one result row, the way Windows File Explorer shows a
// file: a flat coloured file-type icon on the left, the file name in
// clear light text, the folder path underneath in dimmer text, and
// the size and date on the right where they fit. No emoji — the
// icons are plain inline SVG. Used for search results, folder
// results, duplicate rows and organize preview rows.

import type { ReactNode } from 'react';
import { Button } from '@astryxdesign/core/Button';

import type { FileKind } from '../utils/fileTypes';

// Flat colours, one per file type (Explorer-style, dark-friendly).
const KIND_COLORS: Record<FileKind, string> = {
  word: '#2b579a',
  pdf: '#c43e2c',
  image: '#3a7d5d',
  video: '#5b5ea6',
  audio: '#d97b29',
  folder: '#e8b93e',
  sheet: '#217346',
  archive: '#8a6d3b',
  code: '#4b8bbe',
  text: '#6e6e6e',
  file: '#7a7a7a',
};

/** A small flat file icon. A page with a folded corner, a letter or
 *  a mark for the type; a folder is a folder shape. */
export function FileTypeIcon({ kind, label }: { kind: FileKind; label?: string }) {
  const color = KIND_COLORS[kind];
  const title = label ?? kind;
  if (kind === 'folder') {
    return (
      <svg
        width="30"
        height="30"
        viewBox="0 0 32 32"
        role="img"
        aria-label={title}
        focusable="false"
      >
        <path
          d="M2 8a2 2 0 0 1 2-2h7l2.5 3H28a2 2 0 0 1 2 2v15a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V8z"
          fill={color}
        />
        <path d="M2 11h28v15a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V11z" fill="#f7c948" opacity="0.55" />
      </svg>
    );
  }
  return (
    <svg
      width="26"
      height="32"
      viewBox="0 0 26 32"
      role="img"
      aria-label={title}
      focusable="false"
    >
      <path
        d="M4 1h14l5 5v24a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V3a2 2 0 0 1 2-2z"
        fill={color}
      />
      <path d="M18 1l5 5h-5V1z" fill="#ffffff" opacity="0.35" />
      {kind === 'word' && (
        <text x="13" y="22" textAnchor="middle" fontSize="13" fontWeight="700" fill="#ffffff">
          W
        </text>
      )}
      {kind === 'pdf' && (
        <text x="13" y="21" textAnchor="middle" fontSize="8" fontWeight="700" fill="#ffffff">
          PDF
        </text>
      )}
      {kind === 'sheet' && (
        <text x="13" y="22" textAnchor="middle" fontSize="13" fontWeight="700" fill="#ffffff">
          X
        </text>
      )}
      {kind === 'code' && (
        <text x="13" y="21" textAnchor="middle" fontSize="9" fontWeight="700" fill="#ffffff">
          {'</>'}
        </text>
      )}
      {kind === 'image' && (
        <g fill="#ffffff">
          <circle cx="9" cy="10" r="2.4" />
          <polygon points="4,26 11,16 16,22 19,18 23,26" />
        </g>
      )}
      {kind === 'video' && (
        <polygon points="10,11 10,23 21,17" fill="#ffffff" />
      )}
      {kind === 'audio' && (
        <g fill="#ffffff">
          <ellipse cx="10" cy="23" rx="3.2" ry="2.4" />
          <rect x="12.4" y="10" width="1.8" height="13" />
          <ellipse cx="19" cy="20" rx="3.2" ry="2.4" />
          <rect x="21.4" y="7" width="1.8" height="13" />
        </g>
      )}
      {kind === 'archive' && (
        <g stroke="#ffffff" strokeWidth="1.8" strokeLinecap="round">
          <line x1="7" y1="13" x2="19" y2="13" />
          <line x1="7" y1="18" x2="19" y2="18" />
          <line x1="7" y1="23" x2="19" y2="23" />
        </g>
      )}
      {(kind === 'text' || kind === 'file') && (
        <g stroke="#ffffff" strokeWidth="1.8" strokeLinecap="round" opacity="0.85">
          <line x1="7" y1="12" x2="19" y2="12" />
          <line x1="7" y1="17" x2="19" y2="17" />
          <line x1="7" y1="22" x2="16" y2="22" />
        </g>
      )}
    </svg>
  );
}

interface FileRowProps {
  /** File type (decides the icon); pass 'folder' for folders. */
  kind: FileKind;
  /** File or folder name — the clear line. */
  name: string;
  /** Folder path underneath, in dimmer text. */
  folder: string;
  /** Size text on the right ("1.5 MB"), when known. */
  sizeText?: string;
  /** Date text on the right ("12 Nov 2026"), when known. */
  dateText?: string;
  /** One line of matching text, under the path. */
  snippet?: string;
  /** Button on the right ("Open", "Open folder"). */
  actionLabel?: string;
  onAction?: () => void;
  /** Extra control on the right (a checkbox, a "keep" badge). */
  extra?: ReactNode;
}

/** One Explorer-style row. */
export function FileRow({
  kind,
  name,
  folder,
  sizeText,
  dateText,
  snippet,
  actionLabel,
  onAction,
  extra,
}: FileRowProps) {
  return (
    <div className="dj-file-row">
      <span className="dj-file-icon">
        <FileTypeIcon kind={kind} label={name} />
      </span>
      <div className="dj-file-main">
        <div className="dj-file-name">{name}</div>
        <div className="dj-file-path">{folder}</div>
        {snippet ? <div className="dj-file-snippet">{snippet}</div> : null}
      </div>
      {sizeText || dateText ? (
        <div className="dj-file-meta">
          {sizeText ? <span>{sizeText}</span> : null}
          {dateText ? <span>{dateText}</span> : null}
        </div>
      ) : null}
      {extra}
      {actionLabel && onAction ? (
        <Button label={actionLabel} variant="secondary" onClick={onAction} />
      ) : null}
    </div>
  );
}
