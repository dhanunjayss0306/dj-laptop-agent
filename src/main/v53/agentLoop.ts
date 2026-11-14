// DJ v5.3 — OpenClaw inclusion (idea only, no OpenClaw code).
// OpenClaw runs one Gateway with an agent loop (think, call a tool,
// observe the result, repeat until done), memory as plain Markdown
// files (MEMORY.md + daily notes), skills as Markdown playbooks, and
// a heartbeat that wakes the agent on a schedule. DJ takes that
// shape, at DJ size:
//
//   - Agent loop: bounded steps, never infinite. The "think" step
//     is a pluggable decider: with a model up it can be the model;
//     with no model it is Core rules (keyword routing). Either way
//     the loop, the bound, and the observations are the same.
//   - Memory files: MEMORY.md (long-term facts) + memory/YYYY-MM-DD.md
//     (daily notes), plain text in DJ's data folder.
//   - Skill playbooks: *.md files in a skills/ folder; DJ loads the
//     title and body and can follow them as a plan.
//   - Heartbeat: a scheduled check (default 30 min) that re-resolves
//     the capability layer and notes a change in the daily notes.
//     It never acts on files by itself.

import * as fs from 'fs';
import * as path from 'path';

export type ToolFn = (input: string) => Promise<string> | string;

export interface AgentStep {
  thought: string;
  tool?: string;
  observation?: string;
}

export interface AgentResult {
  done: boolean;
  steps: AgentStep[];
  answer: string;
  error?: string;
}

/** What the loop should do next. The default decider is Core rules
 *  (keyword routing); a model-backed decider can be plugged in when
 *  Layer 1 or 2 is up, with the same shape. */
export type ThinkFn = (
  task: string,
  observations: string[],
  tools: string[],
) => { tool: string | null; input: string; done: boolean; thought: string };

/** Default think: call a tool whose name appears in the task, then
 *  answer from the observation. No model needed. Once a tool has
 *  answered, the loop is done — it never calls the same tool twice
 *  for one task. */
export function coreThink(
  task: string,
  observations: string[],
  tools: string[],
): { tool: string | null; input: string; done: boolean; thought: string } {
  if (observations.length > 0) {
    return {
      tool: null,
      input: '',
      done: true,
      thought: observations[observations.length - 1],
    };
  }
  const low = task.toLowerCase();
  for (const name of tools) {
    if (low.includes(name.toLowerCase())) {
      return { tool: name, input: task, done: false, thought: `the task names the ${name} tool` };
    }
  }
  return { tool: null, input: '', done: true, thought: 'no tool matches; answering from what I know' };
}

/** Think, call a tool, observe, repeat — bounded, never infinite. */
export class AgentLoop {
  constructor(private readonly maxSteps = 8) {}

  async run(
    task: string,
    tools: Map<string, ToolFn>,
    think: ThinkFn = coreThink,
  ): Promise<AgentResult> {
    const steps: AgentStep[] = [];
    const observations: string[] = [];
    const names = [...tools.keys()];
    for (let i = 0; i < this.maxSteps; i++) {
      const next = think(task, observations, names);
      if (next.done || !next.tool) {
        steps.push({ thought: next.thought });
        return { done: true, steps, answer: next.thought };
      }
      const fn = tools.get(next.tool);
      if (!fn) {
        steps.push({ thought: next.thought, tool: next.tool, observation: 'tool not found' });
        return { done: false, steps, answer: '', error: `tool not found: ${next.tool}` };
      }
      let observation: string;
      try {
        observation = await fn(next.input);
      } catch (err) {
        observation = `tool failed: ${err instanceof Error ? err.message : String(err)}`;
      }
      steps.push({ thought: next.thought, tool: next.tool, observation });
      observations.push(observation);
    }
    return { done: false, steps, answer: '', error: `stopped after ${this.maxSteps} steps — task not finished` };
  }
}

/** Memory as plain Markdown files, in DJ's data folder. */
export class MemoryFiles {
  constructor(private readonly dataDir: string) {}

  memoryPath(): string {
    return path.join(this.dataDir, 'MEMORY.md');
  }

  dailyPath(date = new Date()): string {
    const day = date.toISOString().slice(0, 10);
    return path.join(this.dataDir, 'memory', `${day}.md`);
  }

  readMemory(): string {
    try {
      return fs.readFileSync(this.memoryPath(), 'utf-8');
    } catch {
      return '';
    }
  }

  /** Append one long-term fact to MEMORY.md. */
  saveFact(text: string): void {
    const line = `- ${new Date().toISOString().slice(0, 10)} ${text.trim()}\n`;
    fs.mkdirSync(path.dirname(this.memoryPath()), { recursive: true });
    fs.appendFileSync(this.memoryPath(), line, 'utf-8');
  }

  /** Append one line to today's daily note. */
  appendDaily(text: string): void {
    const p = this.dailyPath();
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.appendFileSync(p, `- ${new Date().toISOString().slice(11, 19)} ${text.trim()}\n`, 'utf-8');
  }
}

/** One skill playbook: a Markdown file DJ can follow as a plan. */
export interface SkillPlaybook {
  id: string;
  title: string;
  body: string;
  path: string;
}

/** Load *.md playbooks from a skills folder. Missing folder = no
 *  skills, not an error. */
export function loadSkillPlaybooks(dir: string): SkillPlaybook[] {
  let files: string[];
  try {
    files = fs.readdirSync(dir).filter((f) => f.toLowerCase().endsWith('.md'));
  } catch {
    return [];
  }
  const out: SkillPlaybook[] = [];
  for (const file of files.sort()) {
    const p = path.join(dir, file);
    try {
      const body = fs.readFileSync(p, 'utf-8');
      const first = body.split('\n').find((l) => l.trim().length > 0) ?? file;
      const title = first.replace(/^#+\s*/, '').trim() || file;
      out.push({ id: path.basename(file, '.md'), title, body, path: p });
    } catch {
      // Unreadable playbook: skip it, keep the rest.
    }
  }
  return out;
}

/** A scheduled check that runs on a timer. The work itself is
 *  injected, so tests can tick it without waiting. */
export class Heartbeat {
  private timer: ReturnType<typeof setInterval> | null = null;

  constructor(
    private readonly intervalMs: number,
    private readonly work: () => Promise<void> | void,
  ) {}

  start(): void {
    if (this.timer) return;
    this.timer = setInterval(() => {
      void this.work();
    }, this.intervalMs);
    if (typeof this.timer === 'object' && this.timer !== null && 'unref' in this.timer) {
      (this.timer as { unref: () => void }).unref();
    }
  }

  /** Run the work once now (used by tests, and by main on start). */
  async tick(): Promise<void> {
    await this.work();
  }

  stop(): void {
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = null;
    }
  }

  get running(): boolean {
    return this.timer !== null;
  }
}
