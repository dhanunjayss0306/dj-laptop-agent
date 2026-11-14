// DJ v5.3 — jev-chat-jarvis inclusion (idea only, no jev-chat code).
// jev-chat's whole idea is: judge BEFORE you act. It reads the chat,
// judges intent and risk, drafts, checks the draft against the goal,
// scores it, and only then fills the reply in — and it never presses
// send itself. DJ takes that shape for anything destructive:
//
//   Read   — what did the user actually ask for?
//   Judge  — is it safe, is the target clear, is it destructive?
//   Draft  — what would DJ do (the plan, not the action)?
//   Check  — score the plan against the goal; block what fails.
//   Fill   — show the plan to the user. The user confirms. DJ acts.
//
// Scoring follows jev-chat's shape: S = 0.7 * G (goal completion)
// + 0.3 * E (delivery), out of 5. A destructive action always needs
// a human confirm, even when it scores 5. Nothing auto-sends, and
// nothing auto-deletes.

export type JudgeTarget = 'reply' | 'delete' | 'merge' | 'send' | 'organize' | 'open';

export interface JudgeInput {
  kind: JudgeTarget;
  /** The user's words, or the reply DJ drafted. */
  text: string;
  /** Does this change or remove the user's files or messages? */
  destructive: boolean;
  /** How many files/messages the action would touch. */
  targetCount?: number;
  /** What the user actually wants done, in their words. */
  goal?: string;
}

export interface JudgeResult {
  /** 0-5, jev-chat shape: 0.7 * goal + 0.3 * delivery. */
  score: number;
  /** Hard failures: the action must not run. */
  blocked: string[];
  /** Soft warnings: show them, let the user decide. */
  warnings: string[];
  /** True when a human must confirm before DJ acts — always true
   *  for destructive actions. */
  needsConfirm: boolean;
}

/** Judge one action before DJ does it. Pure function, no I/O. */
export function judgeAction(input: JudgeInput): JudgeResult {
  const blocked: string[] = [];
  const warnings: string[] = [];
  const text = (input.text || '').trim();

  // Goal completion (G): is the ask clear and targetable?
  let goalScore = 5;
  if (!text) {
    goalScore = 0;
    blocked.push('nothing to act on');
  }
  if (input.destructive && (input.targetCount ?? 0) === 0) {
    goalScore = 0;
    blocked.push('no target named — nothing would be touched, so nothing runs');
  }
  if (input.destructive && input.targetCount !== undefined && input.targetCount > 50) {
    goalScore = 2;
    warnings.push(`this would touch ${input.targetCount} files — check the list first`);
  }
  if (input.goal && !text.toLowerCase().includes(input.goal.toLowerCase().slice(0, 12))) {
    goalScore = Math.min(goalScore, 3);
    warnings.push('the plan does not clearly match the goal you stated');
  }

  // Delivery (E): is the plan safe to show and run?
  let deliveryScore = 5;
  if (input.destructive) {
    deliveryScore = 4;
    warnings.push('destructive: needs your confirm before anything runs');
  }
  if (input.kind === 'send') {
    deliveryScore = 3;
    warnings.push('sending is always manual — DJ drafts, you press send');
  }

  const score = Math.round((0.7 * goalScore + 0.3 * deliveryScore) * 10) / 10;
  return {
    score,
    blocked,
    warnings,
    needsConfirm: input.destructive || input.kind === 'send' || blocked.length > 0,
  };
}
