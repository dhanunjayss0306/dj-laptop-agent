// DJ v5.4 tests — the AppShell page routing, command palette,
// and capability badge logic. Pure functions from pages.ts, so
// these run without Electron or the app window.

import { describe, expect, it } from 'vitest';

import type { CapabilityStatus } from '../src/shared/types';
import {
  PAGES,
  PALETTE_COMMANDS,
  capabilityBadge,
  filterMemoryLines,
  findPaletteCommand,
  formatUptime,
  isPageId,
  pageLabel,
  type PageId,
} from '../src/renderer/pages';

function makeCapability(overrides: Partial<CapabilityStatus>): CapabilityStatus {
  return {
    layer: 'core',
    local: { available: false, reason: 'local model not running' },
    cloud: { configured: false, valid: null, reason: 'no cloud key set' },
    message: 'Core only: no cloud key set, local model not running',
    checkedAt: new Date().toISOString(),
    ...overrides,
  };
}

describe('pages', () => {
  it('lists exactly DJ\'s seven real sections, in order', () => {
    expect(PAGES.map((p) => p.id)).toEqual([
      'command',
      'files',
      'duplicates',
      'organize',
      'system',
      'memory',
      'settings',
    ]);
  });

  it('labels every page and rejects unknown ids', () => {
    for (const p of PAGES) {
      expect(pageLabel(p.id)).toBe(p.label);
      expect(isPageId(p.id)).toBe(true);
    }
    expect(isPageId('voice-studio')).toBe(false);
    expect(isPageId('')).toBe(false);
  });

  it('every page has a palette command to reach it', () => {
    const ids: PageId[] = [
      'command',
      'files',
      'duplicates',
      'organize',
      'system',
      'memory',
      'settings',
    ];
    for (const id of ids) {
      const cmd = findPaletteCommand(`page:${id}`);
      expect(cmd).toBeDefined();
      expect(cmd?.group).toBe('Pages');
    }
  });

  it('palette actions cover the real actions: rebuild, folders, duplicates, organize, refresh', () => {
    for (const id of [
      'action:rebuild-index',
      'action:folders',
      'action:find-duplicates',
      'action:organize-downloads',
      'action:refresh-status',
    ]) {
      expect(findPaletteCommand(id)).toBeDefined();
    }
    expect(findPaletteCommand('action:does-not-exist')).toBeUndefined();
    // No dead commands: every palette entry resolves to a page or a known action.
    for (const cmd of PALETTE_COMMANDS) {
      expect(cmd.id.startsWith('page:') || cmd.id.startsWith('action:')).toBe(true);
    }
  });
});

describe('capability badge', () => {
  it('cloud layer shows success', () => {
    const b = capabilityBadge(
      makeCapability({
        layer: 'cloud',
        local: { available: true, name: 'Ollama (qwen3.5:9b)' },
        cloud: { configured: true, valid: true },
        message: 'Cloud',
      }),
    );
    expect(b.label).toBe('Cloud');
    expect(b.variant).toBe('success');
    expect(b.dot).toBe('success');
  });

  it('local layer shows the model name in the dot label', () => {
    const b = capabilityBadge(
      makeCapability({
        layer: 'local',
        local: { available: true, name: 'LM Studio (qwen3.5:9b)' },
        message: 'Local model',
      }),
    );
    expect(b.label).toBe('Local model');
    expect(b.variant).toBe('success');
    expect(b.dotLabel).toContain('LM Studio');
  });

  it('expired cloud key shows a warning, not success', () => {
    const b = capabilityBadge(
      makeCapability({
        layer: 'core',
        cloud: { configured: true, valid: false, statusCode: 401, reason: 'cloud key expired (401)' },
        message: 'Core only: cloud key expired (401), local model not running',
      }),
    );
    expect(b.label).toBe('Core only');
    expect(b.variant).toBe('warning');
    expect(b.dot).toBe('warning');
    expect(b.dotLabel).toContain('expired');
  });

  it('plain core (no key, no model) is neutral, and null is checking', () => {
    const plain = capabilityBadge(makeCapability({}));
    expect(plain.variant).toBe('neutral');
    expect(plain.dot).toBe('neutral');
    const missing = capabilityBadge(null);
    expect(missing.label).toBe('Checking');
  });
});

describe('formatUptime', () => {
  it('renders days, hours, minutes, and seconds', () => {
    expect(formatUptime(2 * 86400 + 3 * 3600 + 14 * 60)).toBe('2d 3h 14m');
    expect(formatUptime(5 * 3600 + 12 * 60)).toBe('5h 12m');
    expect(formatUptime(32 * 60)).toBe('32m');
    expect(formatUptime(45)).toBe('45s');
    expect(formatUptime(0)).toBe('0s');
  });
});

describe('filterMemoryLines', () => {
  it('keeps matching lines, case-insensitive, and everything on empty query', () => {
    const text = '- 2026-11-14 learned about Virun\n- 2026-11-15 quiz day\n- 2026-11-16 agents lesson';
    expect(filterMemoryLines(text, 'virun')).toEqual(['- 2026-11-14 learned about Virun']);
    expect(filterMemoryLines(text, 'QUIZ')).toEqual(['- 2026-11-15 quiz day']);
    expect(filterMemoryLines(text, '')).toHaveLength(3);
    expect(filterMemoryLines(text, 'nothing-here')).toEqual([]);
  });
});
