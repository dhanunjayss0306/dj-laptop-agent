# DJ v5.3 — what the 7 repos became inside DJ

DJ stays Electron + TypeScript. Nothing below copies another
project's code, and nothing below is a new runtime: every inclusion
is an idea, re-implemented in TypeScript at DJ size.

## The rule that governs everything

Three capability layers. DJ falls down them, never crashes:

- Layer 2 Cloud — optional provider key. Best answers.
- Layer 1 Local — optional Ollama / LM Studio, if running.
- Layer 0 Core — always on. Rules + tiny embeddings. No model,
  no key, no network. Core file work never depends on Layer 1 or 2.

When the model is gone or the key expires (401/403), DJ falls
back and says so in the sidebar, e.g. "Core only: cloud key
expired, local model not running".

## The 7 inclusions

| Repo | What DJ took | File |
|---|---|---|
| OpenJarvis | 5 primitives config + Trace per interaction + telemetry | `primitives.ts` |
| jev-chat-jarvis | Judge before acting; score, block, human confirms; never auto-send | `judge.ts` |
| isair/jarvis | Name-addressed listening, rolling transcript, fast-judge vs chat-model routing, diary lines | `voice.ts` |
| OpenClaw | Bounded agent loop, MEMORY.md + daily notes, skill playbooks, heartbeat | `agentLoop.ts` |
| nullclaw | Workspace-only security (deny-all), pluggable provider interface | `security.ts` |
| Leon | Skill → Action → Tool → Function, layered memory, verify before success, bounded recovery | `skills.ts` |
| Lucida | Classifier + service-graph idea ONLY. No Lucida code (2014-2016, unmaintained) | `router.ts` |

## What DJ did NOT take

- No Python / PySide6 UI replacement.
- No bundled big model, no always-on model.
- No API key requirement (jev-chat needs OpenRouter; OpenClaw /
  nullclaw normally need a provider key — in DJ those are optional
  Layer 2, never required).
- No Lucida code, no Leon 2.0 as stable.
