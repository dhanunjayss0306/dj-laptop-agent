// DJ v3 — config repository. Which folders DJ is allowed to look in.
// Stored in dj_config.json inside the app data folder. Nothing is
// sent anywhere: the config lives on this laptop only.
//
// Default folders (the user confirms or changes them on first run):
//   Downloads, Desktop, Documents, Pictures, and his user-profile
//   files (for example Antigravity project files under
//   C:\Users\<name>\...). DJ never indexes the whole C: drive —
//   Windows system files would slow the index down and fill the
//   results with junk.

import * as fs from 'fs';
import * as path from 'path';

import type { AppConfig, FolderEntry } from '../shared/types';
import { findDesktop, getConfigPath, getHomeDir } from './utils/paths';

export class ConfigRepository {
  private readonly configPath: string;

  /**
   * @param dataDir the app data folder (defaults to DJ's own data
   *   folder). The config file is dj_config.json inside it.
   */
  constructor(dataDir?: string) {
    this.configPath = dataDir
      ? path.join(dataDir, 'dj_config.json')
      : getConfigPath();
  }

  /** True if the user has saved a config before (not first run). */
  exists(): boolean {
    return fs.existsSync(this.configPath);
  }

  load(): AppConfig {
    if (this.exists()) {
      try {
        const saved = JSON.parse(
          fs.readFileSync(this.configPath, 'utf-8'),
        ) as Partial<AppConfig>;
        return { ...this.defaultConfig(), ...saved };
      } catch {
        // Corrupt config: fall through to defaults.
      }
    }
    return this.defaultConfig();
  }

  save(config: AppConfig): void {
    fs.mkdirSync(path.dirname(this.configPath), { recursive: true });
    fs.writeFileSync(this.configPath, JSON.stringify(config, null, 2), 'utf-8');
  }

  defaultConfig(): AppConfig {
    return { folders: defaultFolders() };
  }
}

/** The five folders DJ looks in by default. */
export function defaultFolders(): FolderEntry[] {
  const home = getHomeDir();
  const antigravity = path.join(home, 'Antigravity');
  // If there is a real Antigravity folder, use it; otherwise point at
  // the profile folder and let the user narrow it down on first run.
  const userFiles = fs.existsSync(antigravity) ? antigravity : home;
  return [
    { path: path.join(home, 'Downloads'), enabled: true },
    { path: findDesktop(home), enabled: true },
    { path: path.join(home, 'Documents'), enabled: true },
    { path: path.join(home, 'Pictures'), enabled: true },
    { path: userFiles, enabled: true },
  ];
}

/** Enabled folder paths that actually exist on this machine. */
export function enabledFolders(config: AppConfig): string[] {
  const out: string[] = [];
  for (const entry of config.folders ?? []) {
    if (!entry.enabled) continue;
    try {
      if (fs.statSync(entry.path).isDirectory()) out.push(entry.path);
    } catch {
      // Missing folder: skip it.
    }
  }
  return out;
}
