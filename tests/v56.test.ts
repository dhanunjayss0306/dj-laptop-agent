// DJ v5.6 — always-running app: auto-start + system tray.
// Tests the pure decisions in services/tray.ts (no Electron
// window needed) and the config persistence of the new settings.

import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { describe, expect, it } from 'vitest';

import {
  buildLoginItemSettings,
  decideCloseAction,
  pickExistingIcon,
  resolveStartAtLogin,
  trayActionFor,
  trayIconCandidates,
  TRAY_MENU,
} from '../src/main/services/tray';
import { ConfigRepository } from '../src/main/config';

describe('resolveStartAtLogin', () => {
  it('uses the saved choice when one exists', () => {
    expect(resolveStartAtLogin(true, false)).toBe(true);
    expect(resolveStartAtLogin(false, true)).toBe(false);
  });

  it('defaults to on in the packaged app, off in dev', () => {
    expect(resolveStartAtLogin(undefined, true)).toBe(true);
    expect(resolveStartAtLogin(undefined, false)).toBe(false);
  });
});

describe('buildLoginItemSettings', () => {
  it('hands Electron exactly openAtLogin', () => {
    expect(buildLoginItemSettings(true)).toEqual({ openAtLogin: true });
    expect(buildLoginItemSettings(false)).toEqual({ openAtLogin: false });
  });
});

describe('decideCloseAction', () => {
  it('hides to the tray when a tray exists', () => {
    expect(decideCloseAction({ hasTray: true, isQuitting: false })).toBe('hide');
  });

  it('quits when there is no tray', () => {
    expect(decideCloseAction({ hasTray: false, isQuitting: false })).toBe('quit');
  });

  it('quits when really quitting, even with a tray', () => {
    expect(decideCloseAction({ hasTray: true, isQuitting: true })).toBe('quit');
  });
});

describe('tray menu', () => {
  it('has Open DJ first and Quit DJ last', () => {
    expect(TRAY_MENU.map((item) => item.id)).toEqual(['open', 'quit']);
    expect(TRAY_MENU[0]?.label).toBe('Open DJ');
    expect(TRAY_MENU[1]?.label).toBe('Quit DJ');
  });

  it('maps ids to actions and rejects unknown ids', () => {
    expect(trayActionFor('open')).toBe('open');
    expect(trayActionFor('quit')).toBe('quit');
    expect(trayActionFor('close')).toBeNull();
    expect(trayActionFor('')).toBeNull();
  });
});

describe('pickExistingIcon', () => {
  it('returns the first candidate that exists', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-tray-'));
    const missing = path.join(dir, 'nope.ico');
    const real = path.join(dir, 'icon.ico');
    fs.writeFileSync(real, 'fake icon');
    expect(pickExistingIcon([missing, real])).toBe(real);
    expect(pickExistingIcon([missing])).toBeNull();
    fs.rmSync(dir, { recursive: true, force: true });
  });

  it('prefers the packaged resources path over the dev assets path', () => {
    const candidates = trayIconCandidates('/fake/resources', '/fake/app');
    expect(candidates[0]).toBe(path.join('/fake/resources', 'tray-icon.ico'));
    expect(candidates[1]).toBe(path.join('/fake/app', 'assets', 'icon.ico'));
  });

  it('finds the real repo icon through the dev candidate', () => {
    const appPath = path.join(__dirname, '..');
    const found = pickExistingIcon(trayIconCandidates('/nonexistent', appPath));
    expect(found).toBe(path.join(appPath, 'assets', 'icon.ico'));
  });
});

describe('config persistence for v5.6 settings', () => {
  it('round-trips startAtLogin and trayNoteSeen', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-config-'));
    const repo = new ConfigRepository(dir);
    const config = repo.load();
    repo.save({ ...config, startAtLogin: false, trayNoteSeen: true });
    const loaded = repo.load();
    expect(loaded.startAtLogin).toBe(false);
    expect(loaded.trayNoteSeen).toBe(true);
    fs.rmSync(dir, { recursive: true, force: true });
  });

  it('leaves both unset by default', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-config-'));
    const repo = new ConfigRepository(dir);
    const config = repo.load();
    expect(config.startAtLogin).toBeUndefined();
    expect(config.trayNoteSeen).toBeUndefined();
    fs.rmSync(dir, { recursive: true, force: true });
  });
});
