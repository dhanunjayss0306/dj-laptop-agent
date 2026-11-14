// DJ v5.3 tests — the fallback the user asked for: when the long
// model is gone or the API key expires, DJ must still run. Plus one
// test per 7-repo inclusion, proving each module does what the
// export file said it would.

import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { describe, expect, it } from 'vitest';

import { CapabilityManager, isAuthError } from '../src/main/v53/capability';
import { defaultPrimitives, TraceStore } from '../src/main/v53/primitives';
import { judgeAction } from '../src/main/v53/judge';
import {
  parseAddressed,
  RollingTranscript,
  routeTask,
} from '../src/main/v53/voice';
import {
  AgentLoop,
  Heartbeat,
  loadSkillPlaybooks,
  MemoryFiles,
} from '../src/main/v53/agentLoop';
import {
  CoreProvider,
  ProviderRegistry,
  WorkspaceGuard,
} from '../src/main/v53/security';
import { LayeredMemory, SkillRegistry } from '../src/main/v53/skills';
import { classifyRequest, serviceGraphFor } from '../src/main/v53/router';
import { BrainService } from '../src/main/services/brainService';
import { ChatService } from '../src/main/services/chatService';
import type { IndexService } from '../src/main/services/indexService';

// -- capability fallback -------------------------------------------------

const noLayers = {
  checkLocal: async () => ({ available: false, reason: 'local model not running' }),
  checkCloud: async () => ({
    configured: false,
    valid: null as boolean | null,
    reason: 'no cloud key set',
  }),
};

describe('fallback (a): no key + no local model => Core still works', () => {
  it('resolves to Core with a plain reason', async () => {
    const manager = new CapabilityManager(noLayers, 0);
    const status = await manager.resolve();
    expect(status.layer).toBe('core');
    expect(status.message).toBe('Core only: local model not running');
  });

  it('the rules brain still decides a search with no model', () => {
    const brain = new BrainService();
    expect(brain.decide('find my Virun pitch')).toEqual({
      action: 'search',
      query: 'my Virun pitch',
    });
  });

  it('core file search still works end to end (ChatService + fake index)', async () => {
    const results = [
      { path: '/tmp/notes.txt', name: 'notes.txt', folder: '/tmp', snippet: 'notes', score: 1 },
    ];
    const fakeIndexer = {
      listFolders: () => [{ path: '/tmp', name: 'tmp', parent: '/' }],
      search: async () => results,
      findFolders: () => [],
      getFileText: async () => 'hello',
      listRecent: () => [],
    } as unknown as IndexService;
    const chat = new ChatService(fakeIndexer, () => ['/tmp']);
    const res = await chat.handle('find my notes');
    expect(res.kind).toBe('search');
    if (res.kind === 'search') expect(res.results).toHaveLength(1);
  });
});

describe('fallback (b): expired/invalid cloud key (401) falls back', () => {
  it('401 on cloud falls back to the local model', async () => {
    const manager = new CapabilityManager(
      {
        checkLocal: async () => ({ available: true, name: 'Ollama (qwen3.5:9b)' }),
        checkCloud: async () => ({
          configured: true,
          valid: false,
          statusCode: 401,
          reason: 'cloud key expired (401)',
        }),
      },
      0,
    );
    const status = await manager.resolve();
    expect(status.layer).toBe('local');
    expect(status.message).toContain('cloud key expired (401)');
  });

  it('401 on cloud AND local down falls back to Core', async () => {
    const manager = new CapabilityManager(
      {
        checkLocal: async () => ({ available: false, reason: 'local model not running' }),
        checkCloud: async () => ({
          configured: true,
          valid: false,
          statusCode: 401,
          reason: 'cloud key expired (401)',
        }),
      },
      0,
    );
    const status = await manager.resolve();
    expect(status.layer).toBe('core');
    expect(status.message).toBe('Core only: cloud key expired (401), local model not running');
  });

  it('401/403 are auth errors; 500 is not', () => {
    expect(isAuthError(401)).toBe(true);
    expect(isAuthError(403)).toBe(true);
    expect(isAuthError(500)).toBe(false);
    expect(isAuthError(undefined)).toBe(false);
  });
});

describe('fallback (c): local model down => Core with a plain message', () => {
  it('resolves to Core and says the local model is not running', async () => {
    const manager = new CapabilityManager(noLayers, 0);
    const status = await manager.resolve();
    expect(status.layer).toBe('core');
    expect(status.message).toContain('local model not running');
  });

  it('a failed probe is an unavailable layer, never a crash', async () => {
    const manager = new CapabilityManager(
      {
        checkLocal: async () => {
          throw new Error('connection refused');
        },
        checkCloud: async () => {
          throw new Error('network down');
        },
      },
      0,
    );
    const status = await manager.resolve();
    expect(status.layer).toBe('core');
  });
});

// -- the 7 inclusions ------------------------------------------------------

describe('OpenJarvis: primitives + traces', () => {
  it('defaults are Core-only: no engine, fallback ends at core', () => {
    const p = defaultPrimitives();
    expect(p.engine.kind).toBe('none');
    expect(p.intelligence.fallbackChain[p.intelligence.fallbackChain.length - 1]).toBe('core');
  });
  it('telemetry counts fallbacks', () => {
    const store = new TraceStore(10);
    store.record({ route: 'chat', tools: ['search'], ms: 50, layer: 'core' });
    store.record({ route: 'chat', tools: ['search'], ms: 80, layer: 'core', fallback: 'cloud 401 -> local' });
    expect(store.telemetry().fallbacks).toBe(1);
    expect(store.telemetry().count).toBe(2);
  });
});

describe('jev-chat: judge before acting', () => {
  it('a delete with no target is blocked', () => {
    const r = judgeAction({ kind: 'delete', text: 'delete the copies', destructive: true, targetCount: 0 });
    expect(r.blocked.length).toBeGreaterThan(0);
    expect(r.needsConfirm).toBe(true);
  });
  it('a delete with targets needs a human confirm, but is not blocked', () => {
    const r = judgeAction({ kind: 'delete', text: 'delete the copies', destructive: true, targetCount: 3 });
    expect(r.blocked).toEqual([]);
    expect(r.needsConfirm).toBe(true);
  });
  it('a plain search is not blocked and scores 5', () => {
    const r = judgeAction({ kind: 'reply', text: 'find my notes', destructive: false });
    expect(r.blocked).toEqual([]);
    expect(r.score).toBe(5);
  });
  it('ChatService delete/merge with no targets is blocked, nothing runs', async () => {
    const fakeIndexer = {
      listFolders: () => [],
      search: async () => [],
      findFolders: () => [],
      getFileText: async () => '',
      listRecent: () => [],
    } as unknown as IndexService;
    const chat = new ChatService(fakeIndexer, () => []);
    const del = await chat.deleteDuplicates([]);
    expect(del.deleted).toEqual([]);
    expect(del.errors.length).toBeGreaterThan(0);
    expect(chat.mergeDuplicates([], '/tmp')).toEqual({ moved: [], errors: expect.any(Array) });
  });
});

describe('isair Jarvis: voice-first', () => {
  it('"DJ, find my notes" is addressed; plain talk is not', () => {
    expect(parseAddressed('DJ, find my notes')).toEqual({
      addressed: true,
      query: 'find my notes',
      wakeWord: 'dj',
    });
    expect(parseAddressed('hello there').addressed).toBe(false);
  });
  it('the rolling transcript finds the addressed line', () => {
    const t = new RollingTranscript();
    t.add('we were talking about the trip');
    t.add('DJ, what did we decide?');
    expect(t.findAddressed()?.query).toBe('what did we decide?');
  });
  it('routing: no model => core rules; classify => fast judge; answer => chat model', () => {
    expect(routeTask({ kind: 'classify', modelUp: false })).toBe('core-rules');
    expect(routeTask({ kind: 'classify', modelUp: true })).toBe('fast-judge');
    expect(routeTask({ kind: 'answer', modelUp: true })).toBe('chat-model');
  });
});

describe('OpenClaw: agent loop, memory files, playbooks, heartbeat', () => {
  it('the loop calls the named tool and records the observation', async () => {
    const loop = new AgentLoop(8);
    const tools = new Map([['search', async (q: string) => `found: ${q}`]]);
    const res = await loop.run('search my notes', tools);
    expect(res.done).toBe(true);
    expect(res.steps.some((s) => s.tool === 'search')).toBe(true);
    expect(res.steps.some((s) => s.observation === 'found: search my notes')).toBe(true);
  });
  it('the loop is bounded: it stops after maxSteps', async () => {
    const loop = new AgentLoop(3);
    const tools = new Map([['search', async () => 'more']]);
    const neverDone = () => ({ tool: 'search', input: 'x', done: false, thought: 'again' });
    const res = await loop.run('search forever', tools, neverDone);
    expect(res.done).toBe(false);
    expect(res.steps).toHaveLength(3);
    expect(res.error).toContain('3 steps');
  });
  it('memory files round-trip in a temp folder', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-memory-'));
    const mem = new MemoryFiles(dir);
    mem.saveFact('likes the Virun pitch');
    expect(mem.readMemory()).toContain('likes the Virun pitch');
    mem.appendDaily('layer changed');
    expect(fs.existsSync(mem.dailyPath())).toBe(true);
  });
  it('playbooks load from a folder; a missing folder is empty, not an error', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-skills-'));
    fs.writeFileSync(path.join(dir, 'find.md'), '# Find a file\n\nDo it.\n', 'utf-8');
    const plays = loadSkillPlaybooks(dir);
    expect(plays).toHaveLength(1);
    expect(plays[0].title).toBe('Find a file');
    expect(loadSkillPlaybooks(path.join(dir, 'nope'))).toEqual([]);
  });
  it('heartbeat ticks on demand and stops', async () => {
    let n = 0;
    const hb = new Heartbeat(60_000, () => {
      n += 1;
    });
    await hb.tick();
    expect(n).toBe(1);
    hb.start();
    expect(hb.running).toBe(true);
    hb.stop();
    expect(hb.running).toBe(false);
  });
});

describe('nullclaw: workspace guard + pluggable providers', () => {
  it('a path inside the workspace is allowed; a walk-out is denied', () => {
    const guard = new WorkspaceGuard(['/tmp/allowed']);
    expect(guard.resolve('/tmp/allowed/notes.txt')).toBe(path.resolve('/tmp/allowed/notes.txt'));
    expect(guard.resolve('/tmp/allowed/../secret.txt')).toBeNull();
    expect(guard.resolve('/etc/passwd')).toBeNull();
    expect(guard.resolveUnder('/tmp/allowed', 'sub/file.txt')).toBe(
      path.resolve('/tmp/allowed/sub/file.txt'),
    );
  });
  it('Core is always registered and always healthy', async () => {
    const reg = new ProviderRegistry();
    expect(reg.defaultProvider().id).toBe('core');
    expect(await new CoreProvider().health()).toBe(true);
  });
});

describe('Leon: skills, layered memory, verification', () => {
  it('a skill runs its actions in order and claims success only with evidence', async () => {
    const reg = new SkillRegistry();
    reg.register({
      id: 'organise',
      name: 'Organise',
      keywords: ['organise', 'organize'],
      actions: [
        { id: 'plan', name: 'Plan', tool: 'plan', input: 'downloads' },
        { id: 'move', name: 'Move', tool: 'move', input: 'downloads' },
      ],
    });
    expect(reg.findFor('organise my downloads')?.id).toBe('organise');
    const tools = new Map([
      ['plan', async () => ({ ok: true, evidence: '3 moves planned' })],
      ['move', async () => ({ ok: true, evidence: '3 files moved' })],
    ]);
    const res = await reg.run(reg.get('organise')!, tools);
    expect(res.ok).toBe(true);
  });
  it('a failing tool retries, then the skill stops and names the failed step', async () => {
    const reg = new SkillRegistry();
    reg.register({
      id: 'x',
      name: 'X',
      keywords: ['x'],
      actions: [{ id: 'bad', name: 'Bad', tool: 'bad', input: '' }],
    });
    let attempts = 0;
    const tools = new Map([
      [
        'bad',
        async () => {
          attempts += 1;
          return { ok: false, error: 'boom' };
        },
      ],
    ]);
    const res = await reg.run(reg.get('x')!, tools);
    expect(res.ok).toBe(false);
    expect(res.failedAt).toBe('bad');
    expect(attempts).toBe(3); // first try + 2 retries, then stop
  });
  it('layered memory: temporary and persistent round-trip', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dj-lmem-'));
    const mem = new LayeredMemory(dir);
    mem.remember('temporary', 'x', '1');
    mem.remember('persistent', 'name', 'Dhanunjay');
    expect(mem.recall('temporary', 'x')).toBe('1');
    expect(new LayeredMemory(dir).recall('persistent', 'name')).toBe('Dhanunjay');
  });
});

describe('Lucida (idea only): classifier + service graph', () => {
  it('routes file, text, image, and system requests', () => {
    expect(classifyRequest('open index.html').type).toBe('file');
    expect(classifyRequest('what is 2 + 2').type).toBe('text');
    expect(classifyRequest('show me this photo').type).toBe('image');
    expect(classifyRequest('how much disk space is left').type).toBe('system');
  });
  it('a file request graphs to classify -> search -> open', () => {
    expect(serviceGraphFor('file')).toEqual(['classify', 'search', 'open']);
  });
});
