// DJ v5.4 — page routing, command-palette commands, and display
// logic for the AppShell UI. Pure functions only: nothing here
// touches Electron, the DOM, or the network, so vitest can cover
// it without the app running.

import type { CapabilityStatus } from '../shared/types';

export type PageId =
  | 'command'
  | 'files'
  | 'duplicates'
  | 'organize'
  | 'system'
  | 'memory'
  | 'settings';

export interface PageDef {
  id: PageId;
  label: string;
}

/** DJ's real sections only — one page per thing DJ actually does. */
export const PAGES: PageDef[] = [
  { id: 'command', label: 'Command Center' },
  { id: 'files', label: 'Files' },
  { id: 'duplicates', label: 'Duplicates' },
  { id: 'organize', label: 'Organize' },
  { id: 'system', label: 'System' },
  { id: 'memory', label: 'Memory' },
  { id: 'settings', label: 'Settings' },
];

export function pageLabel(id: PageId): string {
  return PAGES.find((p) => p.id === id)?.label ?? 'Command Center';
}

export function isPageId(value: string): value is PageId {
  return PAGES.some((p) => p.id === value);
}

/** One command-palette entry: go to a page, or run a real action. */
export interface PaletteCommand {
  id: string;
  label: string;
  group: string;
  keywords: string[];
}

export const PALETTE_COMMANDS: PaletteCommand[] = [
  ...PAGES.map((p) => ({
    id: `page:${p.id}`,
    label: `Go to ${p.label}`,
    group: 'Pages',
    keywords: [p.label.toLowerCase()],
  })),
  {
    id: 'action:rebuild-index',
    label: 'Rebuild index',
    group: 'Actions',
    keywords: ['index', 'rebuild', 'scan'],
  },
  {
    id: 'action:folders',
    label: 'Open folders settings',
    group: 'Actions',
    keywords: ['folders', 'settings', 'add folder'],
  },
  {
    id: 'action:find-duplicates',
    label: 'Find duplicates',
    group: 'Actions',
    keywords: ['duplicates', 'copies', 'extra'],
  },
  {
    id: 'action:organize-downloads',
    label: 'Organize Downloads',
    group: 'Actions',
    keywords: ['organize', 'downloads', 'move'],
  },
  {
    id: 'action:refresh-status',
    label: 'Refresh status',
    group: 'Actions',
    keywords: ['refresh', 'status', 'reload'],
  },
];

export function findPaletteCommand(id: string): PaletteCommand | undefined {
  return PALETTE_COMMANDS.find((c) => c.id === id);
}

/** What the capability badge in the top nav shows. The layer comes
 *  from v5.3; the wording is plain: when the key expired, the badge
 *  says so instead of pretending everything is fine. */
export interface CapabilityBadge {
  label: string;
  variant: 'neutral' | 'info' | 'success' | 'warning' | 'error';
  dot: 'success' | 'warning' | 'error' | 'accent' | 'neutral';
  dotLabel: string;
}

export function capabilityBadge(cap: CapabilityStatus | null): CapabilityBadge {
  if (!cap) {
    return { label: 'Checking', variant: 'neutral', dot: 'neutral', dotLabel: 'Checking layers' };
  }
  if (cap.layer === 'cloud') {
    return { label: 'Cloud', variant: 'success', dot: 'success', dotLabel: 'Cloud layer active' };
  }
  if (cap.layer === 'local') {
    return {
      label: 'Local model',
      variant: 'success',
      dot: 'success',
      dotLabel: `Local model active: ${cap.local.name ?? 'running'}`,
    };
  }
  if (cap.cloud.valid === false) {
    return {
      label: 'Core only',
      variant: 'warning',
      dot: 'warning',
      dotLabel: 'Cloud key expired or invalid, running on Core',
    };
  }
  return { label: 'Core only', variant: 'neutral', dot: 'neutral', dotLabel: 'Core layer, no model or key' };
}

/** Seconds of uptime as plain words, e.g. "2d 3h 14m", "5h 12m",
 *  "32m", "45s". */
export function formatUptime(totalSeconds: number): string {
  const s = Math.max(0, Math.floor(totalSeconds));
  const days = Math.floor(s / 86400);
  const hours = Math.floor((s % 86400) / 3600);
  const minutes = Math.floor((s % 3600) / 60);
  const seconds = s % 60;
  if (days > 0) return `${days}d ${hours}h ${minutes}m`;
  if (hours > 0) return `${hours}h ${minutes}m`;
  if (minutes > 0) return `${minutes}m`;
  return `${seconds}s`;
}

/** Keep only the lines that mention the query (case-insensitive).
 *  Empty query keeps everything. */
export function filterMemoryLines(text: string, query: string): string[] {
  const q = query.trim().toLowerCase();
  const lines = text.split('\n');
  if (!q) return lines;
  return lines.filter((l) => l.toLowerCase().includes(q));
}
