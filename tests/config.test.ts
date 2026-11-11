// DJ v3.1 tests — config: adding a folder (Folders dialog "Add
// folder") persists in dj_config.json and survives a reload.

import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { describe, expect, it } from 'vitest';

import { ConfigRepository } from '../src/main/config';

describe('ConfigRepository: add folder', () => {
  it('an added folder saves and loads back', () => {
    const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-config-'));
    const repo = new ConfigRepository(dataDir);
    const config = repo.load();
    const aupro = path.join(os.tmpdir(), 'AuPro');
    const next = {
      folders: [...config.folders, { path: aupro, enabled: true }],
    };
    repo.save(next);
    const reloaded = new ConfigRepository(dataDir).load();
    expect(reloaded.folders.map((f) => f.path)).toContain(aupro);
    expect(reloaded.folders.find((f) => f.path === aupro)?.enabled).toBe(true);
  });
  it('removing a folder saves too', () => {
    const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-config-'));
    const repo = new ConfigRepository(dataDir);
    const config = repo.load();
    const first = config.folders[0].path;
    repo.save({ folders: config.folders.slice(1) });
    const reloaded = new ConfigRepository(dataDir).load();
    expect(reloaded.folders.map((f) => f.path)).not.toContain(first);
  });
});
