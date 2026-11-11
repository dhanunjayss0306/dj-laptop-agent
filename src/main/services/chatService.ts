// DJ v3 — chat service. Takes one message from the user, decides
// what it means (rules brain), does it (actions), and returns one
// structured answer the UI can render. This is the thin orchestration
// layer: the brain decides, the services act, this file only wires
// them together.

import type { ChatResponse, OrganizeMove, OrganizeRange } from '../../shared/types';
import type { IndexService } from './indexService';
import { BrainService, HELP_TEXT, parseOrganizeRange, rangeLabel } from './brainService';
import { DuplicateService } from './duplicateService';
import { openApp } from './appLauncher';
import { openFile } from './actions';
import { OrganizeService } from './organizeService';
import { summarizeText } from './summarizeService';
import { getDownloadsDir, getHomeDir } from '../utils/paths';

export class ChatService {
  private readonly brain = new BrainService();
  private readonly organize = new OrganizeService();
  private readonly duplicates = new DuplicateService();

  constructor(
    private readonly indexer: IndexService,
    /** Current enabled index folders (the UI's folder list). */
    private readonly getFolders: () => string[],
  ) {}

  /** Handle one user message. Always returns a response. */
  async handle(text: string): Promise<ChatResponse> {
    const action = this.brain.decide(text);
    switch (action.action) {
      case 'help':
        return { kind: 'help', text: HELP_TEXT };

      case 'search': {
        const results = await this.indexer.search(action.query, 8);
        if (results.length === 0) {
          return {
            kind: 'message',
            text:
              `I could not find anything about '${action.query}' in your folders.\n\n` +
              'Try different words, or click Rebuild index if you added files recently.\n\n' +
              HELP_TEXT,
          };
        }
        return {
          kind: 'search',
          text: `I found ${results.length} file(s) about '${action.query}'. Click Open on any of them.`,
          results,
        };
      }

      case 'open': {
        const results = await this.indexer.search(action.query, 8);
        if (results.length === 0) {
          return {
            kind: 'message',
            text: `I could not find a file about '${action.query}'.`,
          };
        }
        const top = results[0];
        const opened = await openFile(top.path);
        return {
          kind: 'opened',
          text: opened.ok
            ? `Opened ${top.name}.`
            : `${opened.message} Here is what I found instead:`,
          results,
        };
      }

      case 'summarize': {
        const results = await this.indexer.search(action.query, 3);
        if (results.length === 0) {
          return {
            kind: 'message',
            text: `I could not find a file about '${action.query}' to summarize.`,
          };
        }
        const top = results[0];
        const fileText = await this.indexer.getFileText(top.path);
        const { summary, usedFirstLines } = summarizeText(fileText, top.name);
        return {
          kind: 'summary',
          text: `Summary of ${top.name}:`,
          fileName: top.name,
          summary,
          note: usedFirstLines
            ? 'Summary from the file itself (first lines) — DJ has no AI model, so it picks the key sentences out of the file.'
            : 'Summary picked from the file itself — DJ has no AI model, so it picks the key sentences out of the file.',
        };
      }

      case 'organize': {
        const range = parseOrganizeRange(action.query);
        if (!range) {
          return {
            kind: 'ask-range',
            text: 'Which days should I organize in Downloads?',
          };
        }
        return this.planOrganize(range);
      }

      case 'duplicates': {
        const groups = this.duplicates.find(this.getFolders());
        if (groups.length === 0) {
          return { kind: 'message', text: 'I found no extra copies in your folders.' };
        }
        const total = groups.reduce((n, g) => n + (g.files.length - 1), 0);
        const hint =
          action.query === 'delete'
            ? ' Tick the copies you want rid of, then click Delete selected copies — they go to the Recycle Bin, only after you confirm.'
            : action.query === 'merge'
              ? ' Pick a folder below and click Merge — I will keep one copy where it is and move the rest there.'
              : ' The first copy in each group is always kept.';
        return {
          kind: 'duplicates',
          text: `I found ${groups.length} group(s) of extra copies (${total} extra file(s)).${hint}`,
          groups,
        };
      }

      case 'list': {
        const recent = this.indexer.listRecent(10);
        if (recent.length === 0) {
          return { kind: 'message', text: 'I have not indexed any files yet. Click Rebuild index first.' };
        }
        return {
          kind: 'search',
          text: 'Here are your newest indexed files:',
          results: recent.map((r) => ({
            path: r.path,
            name: r.name,
            folder: r.folder,
            snippet: '',
            score: 0,
          })),
        };
      }

      case 'openApp': {
        const result = await openApp(action.query);
        return { kind: 'message', text: result.message };
      }

      default:
        return { kind: 'help', text: HELP_TEXT };
    }
  }

  /** Plan an organize for a range (used by chat and by the UI). */
  planOrganize(range: OrganizeRange): ChatResponse {
    const downloads = getDownloadsDir(getHomeDir());
    const plan = this.organize.plan(downloads, range);
    if (plan.length === 0) {
      return {
        kind: 'message',
        text: `Nothing to organize in Downloads for ${rangeLabel(range)} — no files added then.`,
      };
    }
    return {
      kind: 'organize-plan',
      text: `Here is what I will move in Downloads (${rangeLabel(range)}). Nothing moves until you say Yes.`,
      label: rangeLabel(range),
      range,
      plan,
    };
  }

  /** Carry out an organize plan the user confirmed. */
  applyOrganize(plan: OrganizeMove[]): ChatResponse {
    const downloads = getDownloadsDir(getHomeDir());
    const { moved, errors, logPath } = this.organize.apply(plan, downloads);
    return {
      kind: 'organize-done',
      text:
        moved.length > 0
          ? `Moved ${moved.length} file(s). Every move is in ${logPath}.`
          : 'Nothing was moved.',
      moved,
      errors,
      logPath,
    };
  }

  /** Delete picked duplicate copies to the Recycle Bin. */
  async deleteDuplicates(paths: string[]): Promise<{ deleted: string[]; errors: string[]; logPath: string }> {
    return this.duplicates.deleteToRecycleBin(paths, getDownloadsDir(getHomeDir()));
  }

  /** Merge one duplicate group into a folder the user picked. */
  mergeDuplicates(paths: string[], targetFolder: string): { moved: string[]; errors: string[] } {
    return this.duplicates.merge(paths, targetFolder);
  }
}
