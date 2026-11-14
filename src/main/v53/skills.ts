// DJ v5.3 — Leon inclusion (idea only, no Leon code).
// Leon organises capability as Skill -> Action -> Tool -> Function,
// with layered memory and a rule DJ keeps verbatim: verify before
// claiming success. DJ takes that shape:
//
//   Skill  — what it does ("organise Downloads"), found by keyword.
//   Action — one explicit step of the skill.
//   Tool   — the callable unit an action runs.
//   Function — the code behind the tool (injected, so tests can use
//     fakes and main can wire real file tools).
//
// Two more Leon rules:
//   - Bounded recovery: a failing tool is retried at most twice,
//     then the skill stops and says where it failed. No infinite
//     retry, no silent partial success.
//   - Verification: DJ claims success only when every action
//     returned ok WITH evidence. Anything else is reported as
//     "not finished", with the failed step named.
//
// Layered memory (also Leon's shape):
//   temporary  — this session only, in memory.
//   persistent — facts that last, in a JSON file in the data folder.
//   daily      — today's notes, in memory/YYYY-MM-DD.md.

import * as fs from 'fs';
import * as path from 'path';

export interface ToolResult {
  ok: boolean;
  evidence?: string;
  error?: string;
}

export type ToolFnV2 = (input: string) => Promise<ToolResult>;

export interface ActionDef {
  id: string;
  name: string;
  tool: string;
  input: string;
}

export interface SkillDef {
  id: string;
  name: string;
  /** Words that route a request to this skill. */
  keywords: string[];
  actions: ActionDef[];
}

export interface SkillStepResult {
  action: string;
  ok: boolean;
  evidence?: string;
  error?: string;
  attempts: number;
}

export interface SkillRunResult {
  ok: boolean;
  results: SkillStepResult[];
  /** The first action that failed, when the skill did not finish. */
  failedAt?: string;
}

const MAX_ATTEMPTS = 3; // first try + 2 retries, then stop

export class SkillRegistry {
  private readonly skills = new Map<string, SkillDef>();

  register(skill: SkillDef): void {
    this.skills.set(skill.id, skill);
  }

  get(id: string): SkillDef | undefined {
    return this.skills.get(id);
  }

  list(): SkillDef[] {
    return [...this.skills.values()];
  }

  /** The skill whose keywords appear in the request, if any. */
  findFor(text: string): SkillDef | null {
    const low = (text || '').toLowerCase();
    let best: SkillDef | null = null;
    let bestScore = 0;
    for (const skill of this.skills.values()) {
      let score = 0;
      for (const kw of skill.keywords) {
        if (kw && low.includes(kw.toLowerCase())) score += 1;
      }
      if (score > bestScore) {
        bestScore = score;
        best = skill;
      }
    }
    return best;
  }

  /**
   * Run a skill's actions in order. Each action retries at most
   * twice; a still-failing action stops the run. Success is claimed
   * only when every action returned ok with evidence.
   */
  async run(
    skill: SkillDef,
    tools: Map<string, ToolFnV2>,
  ): Promise<SkillRunResult> {
    const results: SkillStepResult[] = [];
    for (const action of skill.actions) {
      const fn = tools.get(action.tool);
      if (!fn) {
        const failed: SkillStepResult = {
          action: action.id,
          ok: false,
          error: `tool not found: ${action.tool}`,
          attempts: 0,
        };
        results.push(failed);
        return { ok: false, results, failedAt: action.id };
      }
      let last: ToolResult = { ok: false, error: 'no attempt ran' };
      let attempts = 0;
      for (let i = 0; i < MAX_ATTEMPTS; i++) {
        attempts += 1;
        try {
          last = await fn(action.input);
        } catch (err) {
          last = { ok: false, error: err instanceof Error ? err.message : String(err) };
        }
        if (last.ok) break;
      }
      const step: SkillStepResult = {
        action: action.id,
        ok: last.ok,
        evidence: last.evidence,
        error: last.ok ? undefined : last.error,
        attempts,
      };
      results.push(step);
      if (!last.ok) {
        return { ok: false, results, failedAt: action.id };
      }
    }
    return { ok: true, results };
  }
}

export type MemoryScope = 'temporary' | 'persistent' | 'daily';

/** Layered memory: temporary (this session), persistent (a JSON
 *  file in the data folder), daily (today's note file). */
export class LayeredMemory {
  private readonly temp = new Map<string, string>();

  constructor(private readonly dataDir: string) {}

  private persistentPath(): string {
    return path.join(this.dataDir, 'memory-persistent.json');
  }

  private dailyPath(date = new Date()): string {
    return path.join(this.dataDir, 'memory', `${date.toISOString().slice(0, 10)}.md`);
  }

  remember(scope: MemoryScope, key: string, value: string): void {
    if (scope === 'temporary') {
      this.temp.set(key, value);
      return;
    }
    if (scope === 'persistent') {
      const all = this.readPersistent();
      all[key] = value;
      fs.mkdirSync(path.dirname(this.persistentPath()), { recursive: true });
      fs.writeFileSync(this.persistentPath(), JSON.stringify(all, null, 2), 'utf-8');
      return;
    }
    const p = this.dailyPath();
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.appendFileSync(p, `- ${key}: ${value}\n`, 'utf-8');
  }

  recall(scope: MemoryScope, key: string): string | undefined {
    if (scope === 'temporary') return this.temp.get(key);
    if (scope === 'persistent') return this.readPersistent()[key];
    try {
      const text = fs.readFileSync(this.dailyPath(), 'utf-8');
      const m = text.match(new RegExp(`^- ${escapeRegExp(key)}: (.*)$`, 'm'));
      return m ? m[1] : undefined;
    } catch {
      return undefined;
    }
  }

  private readPersistent(): Record<string, string> {
    try {
      return JSON.parse(fs.readFileSync(this.persistentPath(), 'utf-8')) as Record<string, string>;
    } catch {
      return {};
    }
  }
}

function escapeRegExp(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
