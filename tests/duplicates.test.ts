// DJ v3 tests — duplicates service: size then SHA-256 grouping,
// delete to Recycle Bin (stubbed), merge.

import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { describe, expect, it } from 'vitest';

import { DuplicateService } from '../src/main/services/duplicateService';

const service = new DuplicateService();

function makeTree(files: Record<string, string>): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-dup-'));
  for (const [name, content] of Object.entries(files)) {
    const p = path.join(dir, name);
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, content);
  }
  return dir;
}

describe('find: size then content hash', () => {
  it('groups files with identical content', async () => {
    const dir = makeTree({
      'a.txt': 'same content here',
      'sub/b.txt': 'same content here',
      'c.txt': 'different content!',
    });
    const groups = await service.find([dir]);
    expect(groups.length).toBe(1);
    expect(groups[0].files.map((f) => f.name).sort()).toEqual(['a.txt', 'b.txt']);
    expect(groups[0].wasted).toBe('same content here'.length);
  });
  it('same size but different content is NOT a duplicate', async () => {
    const dir = makeTree({ 'a.txt': 'abc', 'b.txt': 'xyz' });
    expect(await service.find([dir])).toEqual([]);
  });
  it('empty files are skipped', async () => {
    const dir = makeTree({ 'a.txt': '', 'b.txt': '' });
    expect(await service.find([dir])).toEqual([]);
  });
  it('biggest waste first', async () => {
    const dir = makeTree({
      'small1.txt': 'x'.repeat(10),
      'small2.txt': 'x'.repeat(10),
      'big1.txt': 'y'.repeat(100),
      'big2.txt': 'y'.repeat(100),
    });
    const groups = await service.find([dir]);
    expect(groups.length).toBe(2);
    expect(groups[0].size).toBe(100);
    expect(groups[1].size).toBe(10);
  });
  it('junk folders are not walked', async () => {
    const dir = makeTree({
      'a.txt': 'dup content',
      'node_modules/b.txt': 'dup content',
      '.git/c.txt': 'dup content',
    });
    const groups = await service.find([dir]);
    expect(groups).toEqual([]);
  });
});

describe('deleteToRecycleBin: stubbed trash', () => {
  it('sends the picked copies to the trash function and logs them', async () => {
    const dir = makeTree({ 'a.txt': 'dup', 'b.txt': 'dup' });
    const trashed: string[] = [];
    const stub = async (paths: string[]): Promise<void> => {
      trashed.push(...paths);
    };
    const logDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-log-'));
    const { deleted, errors, logPath } = await service.deleteToRecycleBin(
      [path.join(dir, 'b.txt')],
      logDir,
      stub,
    );
    expect(errors).toEqual([]);
    expect(deleted).toEqual([path.join(dir, 'b.txt')]);
    expect(trashed).toEqual([path.join(dir, 'b.txt')]);
    const log = fs.readFileSync(logPath, 'utf-8');
    expect(log).toContain('b.txt');
    expect(log).toContain('Recycle Bin (deleted)');
  });
  it('a file that is already gone is reported, not deleted', async () => {
    const logDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-log-'));
    const { deleted, errors } = await service.deleteToRecycleBin(
      [path.join(logDir, 'nope.txt')],
      logDir,
      async () => {},
    );
    expect(deleted).toEqual([]);
    expect(errors.length).toBe(1);
  });
});

describe('merge: keep one, move the rest', () => {
  it('keeps the first copy in place and moves the rest', () => {
    const dir = makeTree({ 'a.txt': 'dup', 'sub/b.txt': 'dup' });
    const target = path.join(dir, 'Merged');
    const { moved, errors } = service.merge(
      [path.join(dir, 'a.txt'), path.join(dir, 'sub', 'b.txt')],
      target,
    );
    expect(errors).toEqual([]);
    expect(moved).toEqual([path.join(target, 'b.txt')]);
    expect(fs.existsSync(path.join(dir, 'a.txt'))).toBe(true);
    expect(fs.existsSync(path.join(target, 'b.txt'))).toBe(true);
    expect(fs.existsSync(path.join(dir, 'sub', 'b.txt'))).toBe(false);
  });
  it('never overwrites in the target folder', () => {
    const dir = makeTree({ 'a.txt': 'dup', 'b.txt': 'dup' });
    const target = path.join(dir, 'Merged');
    fs.mkdirSync(target);
    fs.writeFileSync(path.join(target, 'b.txt'), 'already there');
    const { moved } = service.merge(
      [path.join(dir, 'a.txt'), path.join(dir, 'b.txt')],
      target,
    );
    expect(moved).toEqual([path.join(target, 'b-1.txt')]);
    expect(fs.readFileSync(path.join(target, 'b.txt'), 'utf-8')).toBe('already there');
  });
  it('a group of one is refused', () => {
    const dir = makeTree({ 'a.txt': 'dup' });
    const { moved, errors } = service.merge([path.join(dir, 'a.txt')], path.join(dir, 'Merged'));
    expect(moved).toEqual([]);
    expect(errors.length).toBe(1);
  });
});
