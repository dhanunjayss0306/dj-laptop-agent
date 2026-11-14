// DJ v5.3 — nullclaw inclusion (idea only, no nullclaw code).
// nullclaw is a tiny, fast, from-scratch agent runtime in Zig. DJ
// takes two of its ideas, in TypeScript:
//
//   - Workspace-only security: the agent may only touch files
//     inside the folders the user allowed. Everything else is
//     denied by default — including ".." escapes and absolute
//     paths outside the workspace. Deny-all is the default, not
//     something you opt into.
//   - Pluggable providers: a model provider is an interface, not a
//     hardcoded call. Providers register by id; the active one is
//     picked from config. The Core provider (rules only) is always
//     registered and always healthy, so DJ works with zero providers
//     configured.
//
// DJ does not copy nullclaw's binary, its Zig code, or its benchmark
// claims — only the two ideas above.

import * as path from 'path';

export class WorkspaceGuard {
  private readonly roots: string[];

  /**
   * @param roots absolute folder paths DJ is allowed to touch
   *   (the user's enabled index folders). Anything else is denied.
   */
  constructor(roots: string[]) {
    this.roots = roots
      .map((r) => path.resolve(r))
      .filter((r) => r.length > 0);
  }

  /**
   * Resolve a path to an absolute path inside the workspace, or
   * null when it escapes (a ".." walk-out, or an absolute path
   * outside every root). Null means "do not touch this file".
   */
  resolve(p: string): string | null {
    if (!p) return null;
    const abs = path.isAbsolute(p) ? path.resolve(p) : null;
    if (!abs) return null;
    for (const root of this.roots) {
      if (abs === root || abs.startsWith(root + path.sep)) return abs;
    }
    return null;
  }

  /** Resolve a path relative to one root folder. */
  resolveUnder(root: string, rel: string): string | null {
    const abs = path.resolve(root, rel);
    return this.resolve(abs);
  }

  isAllowed(p: string): boolean {
    return this.resolve(p) !== null;
  }
}

/** A model provider: anything that can answer text and say whether
 *  it is up. Local models, cloud models, and Core rules all speak
 *  this one interface, so the active provider is a config choice,
 *  not a code change. */
export interface ModelProvider {
  id: string;
  kind: 'core' | 'local' | 'cloud';
  chat(prompt: string): Promise<string>;
  health(): Promise<boolean>;
}

/** The Core provider: rules only, no model, no key, no network.
 *  Always healthy — it is the provider DJ falls back to. */
export class CoreProvider implements ModelProvider {
  readonly id = 'core';
  readonly kind = 'core' as const;

  async chat(_prompt: string): Promise<string> {
    return 'Core only: I can find, open, organise, and summarise your files with rules — no model is running, so I cannot chat freely.';
  }

  async health(): Promise<boolean> {
    return true;
  }
}

export class ProviderRegistry {
  private readonly providers = new Map<string, ModelProvider>();

  constructor() {
    this.register(new CoreProvider());
  }

  register(provider: ModelProvider): void {
    this.providers.set(provider.id, provider);
  }

  get(id: string): ModelProvider | undefined {
    return this.providers.get(id);
  }

  list(): ModelProvider[] {
    return [...this.providers.values()];
  }

  /** The provider DJ uses when nothing else is up: Core. */
  defaultProvider(): ModelProvider {
    return this.providers.get('core') as ModelProvider;
  }
}
