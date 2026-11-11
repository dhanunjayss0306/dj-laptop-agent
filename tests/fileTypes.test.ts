// DJ v3.2 tests — Explorer-style file types: which icon a file
// gets, and how its size and date are shown on the row.

import { describe, expect, it } from 'vitest';

import { formatBytes, formatDate, getFileKind } from '../src/renderer/utils/fileTypes';

describe('getFileKind: extension decides the icon', () => {
  it('Word documents', () => {
    expect(getFileKind('report.docx')).toBe('word');
    expect(getFileKind('old.doc')).toBe('word');
    expect(getFileKind('REPORT.DOCX')).toBe('word');
  });
  it('PDFs', () => {
    expect(getFileKind('OS MODULE 1.pdf')).toBe('pdf');
  });
  it('images', () => {
    for (const name of ['photo.png', 'pic.jpg', 'pic.jpeg', 'anim.gif', 'shot.webp', 'icon.bmp']) {
      expect(getFileKind(name)).toBe('image');
    }
  });
  it('video and audio', () => {
    expect(getFileKind('clip.mp4')).toBe('video');
    expect(getFileKind('movie.mkv')).toBe('video');
    expect(getFileKind('song.mp3')).toBe('audio');
    expect(getFileKind('voice.wav')).toBe('audio');
  });
  it('spreadsheets and archives', () => {
    expect(getFileKind('data.xlsx')).toBe('sheet');
    expect(getFileKind('data.xls')).toBe('sheet');
    expect(getFileKind('pack.zip')).toBe('archive');
    expect(getFileKind('pack.rar')).toBe('archive');
    expect(getFileKind('pack.7z')).toBe('archive');
  });
  it('code and plain text', () => {
    for (const name of ['app.js', 'main.ts', 'script.py', 'index.html', 'style.css', 'data.json']) {
      expect(getFileKind(name)).toBe('code');
    }
    for (const name of ['notes.txt', 'readme.md', 'data.csv', 'app.log']) {
      expect(getFileKind(name)).toBe('text');
    }
  });
  it('unknown or missing extension is a plain file', () => {
    expect(getFileKind('notes.xyz')).toBe('file');
    expect(getFileKind('Makefile')).toBe('file');
    expect(getFileKind('')).toBe('file');
    expect(getFileKind('.gitignore')).toBe('file');
  });
});

describe('formatBytes: Explorer-style sizes', () => {
  it('bytes, KB, MB, GB', () => {
    expect(formatBytes(0)).toBe('0 B');
    expect(formatBytes(512)).toBe('512 B');
    expect(formatBytes(1536)).toBe('1.5 KB');
    expect(formatBytes(1532860)).toBe('1.5 MB');
    expect(formatBytes(2 * 1024 * 1024 * 1024)).toBe('2.00 GB');
  });
  it('bad input shows nothing', () => {
    expect(formatBytes(-1)).toBe('');
    expect(formatBytes(NaN)).toBe('');
  });
});

describe('formatDate: ISO date to a short readable date', () => {
  it('formats an ISO string', () => {
    expect(formatDate('2026-11-12T00:00:00.000Z')).toBe('12 Nov 2026');
  });
  it('empty or invalid input shows nothing', () => {
    expect(formatDate('')).toBe('');
    expect(formatDate('not-a-date')).toBe('');
  });
});
