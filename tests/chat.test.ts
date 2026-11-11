// DJ v3.1 tests — chat helpers: the "in <project>" hint and the
// folder preference for file opens ("open index.html in AuPro").

import { describe, expect, it } from 'vitest';

import { preferInFolder, splitFolderHint } from '../src/main/services/chatService';
import type { SearchResult } from '../src/shared/types';

function result(path: string, name: string, folder: string): SearchResult {
  return { path, name, folder, snippet: '', score: 0 };
}

describe('splitFolderHint', () => {
  it('open index.html in AuPro splits file and project', () => {
    expect(splitFolderHint('index.html in AuPro')).toEqual({
      query: 'index.html',
      hint: 'AuPro',
    });
  });
  it('no " in " means no hint', () => {
    expect(splitFolderHint('index.html')).toEqual({ query: 'index.html', hint: '' });
  });
  it('a multi-word project hint is kept whole', () => {
    expect(splitFolderHint('notes in my project')).toEqual({
      query: 'notes',
      hint: 'my project',
    });
  });
});

describe('preferInFolder', () => {
  const results = [
    result('/projects/OtherApp/index.html', 'index.html', '/projects/OtherApp'),
    result('/projects/AuPro/index.html', 'index.html', '/projects/AuPro'),
    result('/projects/AuPro/readme.md', 'readme.md', '/projects/AuPro'),
  ];
  it("AuPro's index.html jumps first", () => {
    const ranked = preferInFolder(results, 'AuPro');
    expect(ranked[0].path).toBe('/projects/AuPro/index.html');
    expect(ranked).toHaveLength(3);
  });
  it('an unknown hint changes nothing', () => {
    expect(preferInFolder(results, 'zzqxwv')).toEqual(results);
  });
  it('no hint changes nothing', () => {
    expect(preferInFolder(results, '')).toEqual(results);
  });
});
