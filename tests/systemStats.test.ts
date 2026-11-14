// DJ v5.4 tests — the System page numbers and the Memory page
// reads. The CPU percent math is pure (two snapshots in, one
// number out); the memory read runs against a temp data folder
// with real files, the same shape as DJ's data folder.

import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { describe, expect, it } from 'vitest';

import {
  computeCpuPercent,
  readMemoryContent,
  readSystemStats,
} from '../src/main/services/systemStats';

describe('computeCpuPercent', () => {
  it('measures busy time between two snapshots', () => {
    // 4 cores, 1000 ticks each between samples, 250 of them idle.
    const prev = { idle: 4000, total: 4000 };
    const next = { idle: 4250, total: 8000 };
    expect(computeCpuPercent(prev, next)).toBe(93.8);
  });

  it('returns null when nothing advanced or time went backwards', () => {
    expect(computeCpuPercent({ idle: 100, total: 100 }, { idle: 100, total: 100 })).toBeNull();
    expect(computeCpuPercent({ idle: 200, total: 200 }, { idle: 100, total: 100 })).toBeNull();
  });

  it('returns 0 when everything was idle', () => {
    expect(computeCpuPercent({ idle: 0, total: 0 }, { idle: 500, total: 500 })).toBe(0);
  });
});

describe('readSystemStats', () => {
  it('returns real numbers from this machine, never invented ones', async () => {
    const stats = await readSystemStats();
    expect(stats.cpuCores).toBe(os.cpus().length);
    expect(stats.totalMemBytes).toBe(os.totalmem());
    expect(stats.freeMemBytes).toBeGreaterThan(0);
    expect(stats.freeMemBytes).toBeLessThanOrEqual(stats.totalMemBytes);
    expect(stats.uptimeSeconds).toBeGreaterThan(0);
    expect(stats.platform).toContain(os.platform());
    // CPU percent is either a real 0-100 number or null (not measured).
    expect(stats.cpuPercent === null || (stats.cpuPercent >= 0 && stats.cpuPercent <= 100)).toBe(true);
  });
});

describe('readMemoryContent', () => {
  it('reads MEMORY.md and the daily notes, newest first', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-mem-'));
    fs.writeFileSync(path.join(dir, 'MEMORY.md'), '- 2026-11-14 a long-term fact\n');
    fs.mkdirSync(path.join(dir, 'memory'));
    fs.writeFileSync(path.join(dir, 'memory', '2026-11-14.md'), '- 09:00 first day\n');
    fs.writeFileSync(path.join(dir, 'memory', '2026-11-15.md'), '- 10:00 second day\n');
    fs.writeFileSync(path.join(dir, 'memory', 'not-a-date.md'), '- ignored\n');

    const content = readMemoryContent(dir);
    expect(content.memoryMd).toContain('a long-term fact');
    expect(content.daily.map((d) => d.date)).toEqual(['2026-11-15', '2026-11-14']);
    expect(content.daily[0].text).toContain('second day');
  });

  it('returns empty content when the folder has no memory files', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-mem-empty-'));
    const content = readMemoryContent(dir);
    expect(content.memoryMd).toBe('');
    expect(content.daily).toEqual([]);
  });
});
