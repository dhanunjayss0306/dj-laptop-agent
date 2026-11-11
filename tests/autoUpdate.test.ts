// DJ v3.3 tests — self-update from GitHub Releases. The real
// electron-updater only runs in the installed app, so these tests
// check the parts that decide what the user sees: the event-to-state
// mapping, the plain messages, the packaged-only guard, and that
// package.json actually carries the GitHub publish config the updater
// needs (no release yet = no update, and the test would catch a
// missing config before a build ships).

import * as fs from 'fs';
import * as path from 'path';
import { describe, expect, it } from 'vitest';

import {
  UpdateService,
  shouldEnableAutoUpdate,
  updateEventToState,
  updateStatusMessage,
} from '../src/main/services/updateService';
import type { UpdateState } from '../src/shared/types';

describe('updateStatusMessage: plain words for the user', () => {
  it('ready tells him to restart — never restarts by itself', () => {
    expect(updateStatusMessage('ready', '3.3.1')).toBe(
      'DJ 3.3.1 is ready — restart DJ to install it.',
    );
    expect(updateStatusMessage('ready')).toBe('Update ready — restart DJ to install it.');
  });
  it('available names the version and says it is downloading', () => {
    expect(updateStatusMessage('available', '3.3.1')).toBe(
      'DJ 3.3.1 is available — downloading it now.',
    );
  });
  it('error is honest and says DJ keeps working', () => {
    expect(updateStatusMessage('error')).toContain('keeps working as-is');
  });
  it('idle shows nothing', () => {
    expect(updateStatusMessage('idle')).toBe('');
  });
});

describe('updateEventToState: updater events become UI states', () => {
  it('checking, available, downloaded map in order', () => {
    expect(updateEventToState('checking-for-update')).toMatchObject({
      status: 'checking',
    });
    expect(updateEventToState('update-available', { version: '3.3.1' })).toMatchObject({
      status: 'available',
      version: '3.3.1',
    });
    expect(updateEventToState('update-downloaded', { version: '3.3.1' })).toMatchObject({
      status: 'ready',
      version: '3.3.1',
    });
  });
  it('no update available is a quiet up-to-date', () => {
    expect(updateEventToState('update-not-available')).toMatchObject({
      status: 'up-to-date',
    });
  });
  it('download progress is just "downloading" (no percent spam)', () => {
    expect(updateEventToState('download-progress')).toMatchObject({
      status: 'downloading',
    });
  });
  it('an updater error becomes a plain error state, never a crash', () => {
    const s = updateEventToState('error', { message: 'net::ERR_INTERNET_DISCONNECTED' });
    expect(s?.status).toBe('error');
    expect(s?.message).toContain('keeps working as-is');
  });
});

describe('shouldEnableAutoUpdate: installed app only', () => {
  it('on in the packaged app, off in dev', () => {
    expect(shouldEnableAutoUpdate(true)).toBe(true);
    expect(shouldEnableAutoUpdate(false)).toBe(false);
  });
});

describe('UpdateService.check: a failed check is reported, not thrown', () => {
  it('emits an error state when checkForUpdates throws', async () => {
    const seen: UpdateState[] = [];
    const service = new UpdateService((s) => seen.push(s));
    await service.check({
      checkForUpdates: async () => {
        throw new Error('no network');
      },
    });
    expect(seen).toHaveLength(1);
    expect(seen[0].status).toBe('error');
    expect(seen[0].message).toContain('keeps working as-is');
  });
});

describe('package.json: the updater config the build ships', () => {
  it('publishes to the dj-laptop-agent GitHub repo', () => {
    const pkg = JSON.parse(
      fs.readFileSync(path.join(__dirname, '..', 'package.json'), 'utf8'),
    ) as {
      version: string;
      build: {
        publish: { provider: string; owner: string; repo: string };
        extraResources: { from: string; to: string }[];
      };
    };
    expect(pkg.build.publish).toMatchObject({
      provider: 'github',
      owner: 'dhanunjayss0306',
      repo: 'dj-laptop-agent',
    });
    expect(pkg.build.extraResources).toContainEqual({ from: 'resources/models', to: 'models' });
    expect(pkg.version).toBe('3.3.0');
  });
});
