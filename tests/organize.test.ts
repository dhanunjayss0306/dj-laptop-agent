// DJ v3 tests — organize service: destination rules, date ranges,
// plan/apply, never-overwrite, log file.

import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { describe, expect, it } from 'vitest';

import {
  ORGANIZER_LOG,
  destinationFolder,
  freePath,
  OrganizeService,
} from '../src/main/services/organizeService';

const service = new OrganizeService();

describe('destinationFolder: keyword folders first', () => {
  it.each([
    ['Virun pitch.pdf', ['Hackathons', 'Virun-Travel']],
    ['Yatra plan.docx', ['Hackathons', 'Virun-Travel']],
    ['SAPSS report.pdf', ['Hackathons', 'SAPSS-Vishwakarma']],
    ['vishwakarma stage 2.pptx', ['Hackathons', 'SAPSS-Vishwakarma']],
    ['SasyaSakhi notes.txt', ['Hackathons', 'SasyaSakhi-AgriTech']],
    ['soil health data.csv', ['Hackathons', 'SasyaSakhi-AgriTech']],
    ['quantum assignment.pdf', ['Hackathons', 'Quantum']],
    ['hackerrank solutions.py', ['Hackathons', 'HackerRank']],
    ['persona draft.md', ['Hackathons', 'Persona']],
    ['globaltap deck.pptx', ['Hackathons', 'GlobalTap']],
    ['chaiya menu.pdf', ['Projects', 'Chaiya']],
    ['ada lab manual.pdf', ['College']],
    ['WhatsApp Image 2024-01-01.jpg', ['Images', 'WhatsApp']],
    ['ChatGPT Image 2024.png', ['Images', 'ChatGPT']],
    ['Screenshot 2024-01-01.png', ['Images']],
  ])('%s -> %s', (name, expected) => {
    expect(destinationFolder(name)).toEqual(expected);
  });
  it('.env files go to the private folder', () => {
    expect(destinationFolder('notes.env')).toEqual(['_Private-DoNotShare']);
  });
});

describe('destinationFolder: file-type folders', () => {
  it.each([
    ['photo.jpg', ['Images']],
    ['song.mp3', ['Music']],
    ['movie.mp4', ['Movies']],
    ['setup.exe', ['Programs']],
    ['notes.pdf', ['Documents']],
    ['notes.txt', ['Documents']],
    ['data.csv', ['Spreadsheets']],
    ['slides.pptx', ['Presentations']],
    ['app.py', ['Code']],
    ['archive.zip', ['Archives']],
  ])('%s -> %s', (name, expected) => {
    expect(destinationFolder(name)).toEqual(expected);
  });
  it('unknown type goes to _Review', () => {
    expect(destinationFolder('random.xyz')).toEqual(['_Review']);
  });
});

describe('freePath: never overwrite', () => {
  it('returns the path unchanged when free', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-free-'));
    expect(freePath(dir, 'a.txt')).toBe(path.join(dir, 'a.txt'));
  });
  it('adds -1, -2 when the name is taken', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-free-'));
    fs.writeFileSync(path.join(dir, 'a.txt'), 'x');
    expect(freePath(dir, 'a.txt')).toBe(path.join(dir, 'a-1.txt'));
    fs.writeFileSync(path.join(dir, 'a-1.txt'), 'x');
    expect(freePath(dir, 'a.txt')).toBe(path.join(dir, 'a-2.txt'));
  });
});

function makeDownloads(files: { name: string; daysAgo: number; content?: string }[]): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-downloads-'));
  for (const f of files) {
    const p = path.join(dir, f.name);
    fs.writeFileSync(p, f.content ?? 'hello');
    const d = new Date();
    d.setDate(d.getDate() - f.daysAgo);
    fs.utimesSync(p, d, d);
  }
  return dir;
}

describe('plan: date ranges', () => {
  const files = [
    { name: 'today.pdf', daysAgo: 0 },
    { name: 'yesterday.pdf', daysAgo: 1 },
    { name: 'three-days-ago.pdf', daysAgo: 3 },
    { name: 'old.pdf', daysAgo: 30 },
  ];
  it('today plans only today', () => {
    const dir = makeDownloads(files);
    expect(service.plan(dir, { kind: 'today' }).map((m) => m.name)).toEqual(['today.pdf']);
  });
  it('yesterday plans only yesterday', () => {
    const dir = makeDownloads(files);
    expect(service.plan(dir, { kind: 'yesterday' }).map((m) => m.name)).toEqual(['yesterday.pdf']);
  });
  it('last 3 days includes today, yesterday and 3 days ago', () => {
    const dir = makeDownloads(files);
    const names = service.plan(dir, { kind: 'lastDays', days: 3 }).map((m) => m.name);
    expect(names.sort()).toEqual(['three-days-ago.pdf', 'today.pdf', 'yesterday.pdf']);
  });
  it('all plans everything', () => {
    const dir = makeDownloads(files);
    expect(service.plan(dir, { kind: 'all' }).length).toBe(4);
  });
  it('never plans the organizer script or its log', () => {
    const dir = makeDownloads([
      { name: 'organize-downloads.ps1', daysAgo: 0 },
      { name: '_Organizer_Log.csv', daysAgo: 0 },
      { name: 'downloads-preview.csv', daysAgo: 0 },
      { name: 'keep.pdf', daysAgo: 0 },
    ]);
    expect(service.plan(dir, { kind: 'all' }).map((m) => m.name)).toEqual(['keep.pdf']);
  });
});

describe('apply: moves and logs', () => {
  it('moves files into their folders and writes the log', () => {
    const dir = makeDownloads([
      { name: 'photo.jpg', daysAgo: 0 },
      { name: 'notes.pdf', daysAgo: 0 },
    ]);
    const plan = service.plan(dir, { kind: 'all' });
    const { moved, errors, logPath } = service.apply(plan, dir);
    expect(errors).toEqual([]);
    expect(moved.length).toBe(2);
    expect(fs.existsSync(path.join(dir, 'Images', 'photo.jpg'))).toBe(true);
    expect(fs.existsSync(path.join(dir, 'Documents', 'notes.pdf'))).toBe(true);
    expect(fs.existsSync(path.join(dir, 'photo.jpg'))).toBe(false);
    expect(logPath).toBe(path.join(dir, ORGANIZER_LOG));
    const log = fs.readFileSync(logPath, 'utf-8');
    expect(log.split('\n')[0]).toBe('Name,OldPath,NewPath,Date');
    expect(log).toContain('photo.jpg');
    expect(log).toContain('notes.pdf');
  });
  it('never overwrites: a clashing destination gets -1', () => {
    const dir = makeDownloads([{ name: 'notes.pdf', daysAgo: 0 }]);
    const docsDir = path.join(dir, 'Documents');
    fs.mkdirSync(docsDir);
    fs.writeFileSync(path.join(docsDir, 'notes.pdf'), 'already there');
    const plan = service.plan(dir, { kind: 'all' });
    const { moved } = service.apply(plan, dir);
    expect(moved.length).toBe(1);
    expect(moved[0].new).toBe(path.join(docsDir, 'notes-1.pdf'));
    expect(fs.readFileSync(path.join(docsDir, 'notes.pdf'), 'utf-8')).toBe('already there');
  });
  it('a file that vanished before the move is reported, not crashed on', () => {
    const dir = makeDownloads([{ name: 'notes.pdf', daysAgo: 0 }]);
    const plan = service.plan(dir, { kind: 'all' });
    fs.unlinkSync(path.join(dir, 'notes.pdf'));
    const { moved, errors } = service.apply(plan, dir);
    expect(moved).toEqual([]);
    expect(errors.length).toBe(1);
  });
});
