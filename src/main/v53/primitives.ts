// DJ v5.3 — OpenJarvis inclusion (idea only, no OpenJarvis code).
// OpenJarvis is built from five swappable primitives; DJ v5.3 keeps
// the same shape as one config object, so a layer can be swapped
// without rewriting the app:
//
//   intelligence — which model, how big, what falls back to what
//   engine       — the runtime that runs it (ollama / lmstudio /
//                   cloud / none). "none" is a real, valid engine:
//                   it means Layer 0 Core only.
//   agents       — which agent loop answers (simple rules first,
//                   tool-calling loop only when a model exists)
//   toolsMemory  — tools DJ may call, and memory backends
//   learning     — trace-driven feedback: traces record what ran,
//                   and telemetry summarises it (nothing is sent
//                   anywhere; the learning loop only reads traces
//                   on this laptop).
//
// Also: one Trace record per interaction (route, tools used,
// latency, layer, fallback), kept in memory in a bounded ring.

import type { CapabilityLayer, TraceRecord } from '../../shared/types';

export interface DjPrimitives {
  intelligence: {
    /** The local model to prefer, e.g. "qwen3.5:9b". Empty = none. */
    model: string;
    /** What to fall back to, in order. "core" is always last. */
    fallbackChain: CapabilityLayer[];
  };
  engine: {
    kind: 'ollama' | 'lmstudio' | 'cloud' | 'none';
  };
  agents: {
    /** Rules brain first; the tool loop only runs when a model is up. */
    defaultAgent: 'simple' | 'tool-loop';
    maxToolSteps: number;
  };
  toolsMemory: {
    /** Memory backend for facts: plain Markdown files (MEMORY.md +
     *  daily notes) — no vector DB needed for Layer 0. */
    memoryBackend: 'markdown-files';
  };
  learning: {
    /** Keep traces and telemetry on this laptop. */
    enabled: boolean;
    /** Traces are read to improve routing; nothing leaves the laptop. */
    maxTraces: number;
  };
}

/** DJ's default primitives: no model, no key, Core only. Layers 1
 *  and 2 are switched on only when their probe says they are up. */
export function defaultPrimitives(): DjPrimitives {
  return {
    intelligence: { model: '', fallbackChain: ['cloud', 'local', 'core'] },
    engine: { kind: 'none' },
    agents: { defaultAgent: 'simple', maxToolSteps: 8 },
    toolsMemory: { memoryBackend: 'markdown-files' },
    learning: { enabled: true, maxTraces: 200 },
  };
}

/** Bounded in-memory trace store. Oldest traces drop off; nothing
 *  is written to disk and nothing is sent anywhere. */
export class TraceStore {
  private readonly traces: TraceRecord[] = [];
  private counter = 0;

  constructor(private readonly maxTraces = 200) {}

  record(input: Omit<TraceRecord, 'id' | 'at'>): TraceRecord {
    const rec: TraceRecord = {
      ...input,
      id: `tr-${++this.counter}`,
      at: new Date().toISOString(),
    };
    this.traces.push(rec);
    while (this.traces.length > this.maxTraces) this.traces.shift();
    return rec;
  }

  recent(n: number): TraceRecord[] {
    return this.traces.slice(-n);
  }

  get count(): number {
    return this.traces.length;
  }

  /** Telemetry: how many interactions, how slow, how often a layer
   *  fell back. Plain numbers, for the user to see — not a score. */
  telemetry(): {
    count: number;
    avgMs: number;
    toolCalls: number;
    fallbacks: number;
    byLayer: Record<string, number>;
  } {
    const byLayer: Record<string, number> = {};
    let ms = 0;
    let toolCalls = 0;
    let fallbacks = 0;
    for (const t of this.traces) {
      ms += t.ms;
      toolCalls += t.tools.length;
      if (t.fallback) fallbacks += 1;
      byLayer[t.layer] = (byLayer[t.layer] ?? 0) + 1;
    }
    return {
      count: this.traces.length,
      avgMs: this.traces.length === 0 ? 0 : Math.round(ms / this.traces.length),
      toolCalls,
      fallbacks,
      byLayer,
    };
  }
}
