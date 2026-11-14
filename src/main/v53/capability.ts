// DJ v5.3 — capability layers. The user's rule, in code:
// DJ must keep running when the long model is gone or the API key
// expires. So capability is three layers, and DJ always falls down
// them, never up, never crashing:
//
//   Layer 2 Cloud  — optional provider key (OpenAI / Anthropic /
//                      OpenRouter). Best answers, needs a valid key.
//   Layer 1 Local  — optional local model (Ollama / LM Studio) if
//                      it is running. No key, slower, weaker.
//   Layer 0 Core   — ALWAYS on. Rules + tiny local embeddings:
//                      file find/open/delete/merge, organise with
//                      preview, open apps, system info, reminders,
//                      local memory files. Needs no model, no key,
//                      no network. Core file work never depends on
//                      Layer 1 or 2, so it can never break this way.
//
// Probes are injected (functions), so tests can simulate a dead
// model, an expired key, or a 401 without any network. The manager
// never throws: a failed probe is just an unavailable layer.

import type {
  CapabilityLayer,
  CapabilityStatus,
  CloudHealth,
  LocalModelHealth,
} from '../../shared/types';

export interface CapabilityProbes {
  /** Is a local model server answering right now? */
  checkLocal: () => Promise<LocalModelHealth>;
  /** Is a cloud key configured, and does it still work? */
  checkCloud: () => Promise<CloudHealth>;
}

/** A 401 or 403 from a provider means the key is bad or expired —
 *  not a network blip. That is the signal to fall back, not retry. */
export function isAuthError(statusCode: number | undefined): boolean {
  return statusCode === 401 || statusCode === 403;
}

export class CapabilityManager {
  private cached: CapabilityStatus | null = null;
  private cachedAt = 0;

  /**
   * @param probes how to check each optional layer (injected).
   * @param cacheMs how long a resolved layer stays valid (default
   *   30 s — the UI polls status, and a live probe on every poll
   *   would hammer a dead local server).
   */
  constructor(
    private readonly probes: CapabilityProbes,
    private readonly cacheMs = 30_000,
  ) {}

  /** The last resolved status without probing again (null before
   *  the first resolve). */
  last(): CapabilityStatus | null {
    return this.cached;
  }

  /** Resolve the best layer available right now. Always returns a
   *  status — worst case, Layer 0 Core with the reasons why. */
  async resolve(force = false): Promise<CapabilityStatus> {
    const now = Date.now();
    if (!force && this.cached && now - this.cachedAt < this.cacheMs) {
      return this.cached;
    }

    const cloud = await this.safeCheckCloud();
    const local = await this.safeCheckLocal();

    let layer: CapabilityLayer = 'core';
    let message: string;
    if (cloud.configured && cloud.valid === true) {
      layer = 'cloud';
      message = `Cloud${local.available ? ' (local model also available)' : ''}`;
    } else if (local.available) {
      layer = 'local';
      const cloudNote =
        cloud.configured && cloud.valid === false
          ? ` — ${cloud.reason ?? 'cloud key not working'}`
          : '';
      message = `Local model${local.name ? ` (${local.name})` : ''}${cloudNote}`;
    } else {
      const reasons: string[] = [];
      if (cloud.configured && cloud.valid === false) {
        reasons.push(cloud.reason ?? 'cloud key not working');
      } else if (cloud.configured) {
        reasons.push('cloud could not be checked');
      }
      reasons.push(local.reason ?? 'local model not running');
      layer = 'core';
      message = `Core only: ${reasons.join(', ')}`;
    }

    const status: CapabilityStatus = {
      layer,
      local,
      cloud,
      message,
      checkedAt: new Date().toISOString(),
    };
    this.cached = status;
    this.cachedAt = now;
    return status;
  }

  /** A probe that throws is an unavailable layer, never a crash. */
  private async safeCheckLocal(): Promise<LocalModelHealth> {
    try {
      return await this.probes.checkLocal();
    } catch {
      return { available: false, reason: 'local model could not be checked' };
    }
  }

  private async safeCheckCloud(): Promise<CloudHealth> {
    try {
      return await this.probes.checkCloud();
    } catch {
      return { configured: false, valid: null, reason: 'cloud could not be checked' };
    }
  }
}
