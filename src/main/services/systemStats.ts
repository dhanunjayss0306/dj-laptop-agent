// DJ v5.4 — real system numbers for the System page, and the v5.3
// memory files for the Memory page. Everything here is read from
// this laptop only: Node's os module for the numbers, the plain
// Markdown files in DJ's data folder for memory. Nothing is
// estimated or invented — when a number cannot be measured, the
// caller gets null and the UI says so plainly.

import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';

import type { MemoryContent, MemoryDay, SystemStats } from '../../shared/types';
import { MemoryFiles } from '../v53/agentLoop';

export interface CpuSnapshot {
  idle: number;
  total: number;
}

function snapshotCpus(): CpuSnapshot {
  let idle = 0;
  let total = 0;
  for (const cpu of os.cpus()) {
    const t = cpu.times;
    idle += t.idle;
    total += t.user + t.nice + t.sys + t.idle + t.irq;
  }
  return { idle, total };
}

/** CPU use in percent between two snapshots. Null when the samples
 *  are identical or went backwards (nothing to measure). */
export function computeCpuPercent(prev: CpuSnapshot, next: CpuSnapshot): number | null {
  const idleDelta = next.idle - prev.idle;
  const totalDelta = next.total - prev.total;
  if (totalDelta <= 0 || idleDelta < 0) return null;
  return Math.round(((totalDelta - idleDelta) / totalDelta) * 1000) / 10;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Two os.cpus() samples, 500 ms apart, turned into a percent.
 *  On Windows os.loadavg() is always zeros, so this is the honest
 *  way to measure CPU use with the built-in os module. */
export async function sampleCpuPercent(delayMs = 500): Promise<number | null> {
  const prev = snapshotCpus();
  await sleep(delayMs);
  return computeCpuPercent(prev, snapshotCpus());
}

/** Read the real system numbers. Disk usage is left out on purpose:
 *  Node has no reliable built-in call for it on Windows. */
export async function readSystemStats(): Promise<SystemStats> {
  return {
    cpuPercent: await sampleCpuPercent(),
    cpuCores: os.cpus().length,
    totalMemBytes: os.totalmem(),
    freeMemBytes: os.freemem(),
    uptimeSeconds: os.uptime(),
    platform: `${os.platform()} ${os.release()}`,
    checkedAt: new Date().toISOString(),
  };
}

/** Read MEMORY.md plus the daily notes, newest first, at most 14
 *  days. Read-only: nothing here writes. */
export function readMemoryContent(dataDir: string): MemoryContent {
  const files = new MemoryFiles(dataDir);
  const memoryMd = files.readMemory();
  const daily: MemoryDay[] = [];
  const dir = path.join(dataDir, 'memory');
  let names: string[] = [];
  try {
    names = fs
      .readdirSync(dir)
      .filter((f) => /^\d{4}-\d{2}-\d{2}\.md$/.test(f))
      .sort()
      .reverse()
      .slice(0, 14);
  } catch {
    names = [];
  }
  for (const name of names) {
    try {
      daily.push({
        date: name.slice(0, 10),
        text: fs.readFileSync(path.join(dir, name), 'utf-8'),
      });
    } catch {
      // Unreadable note: skip it, keep the rest.
    }
  }
  return { memoryMd, daily };
}
