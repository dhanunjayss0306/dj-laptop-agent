// DJ v3 — one DJ reply in the chat, rendered by response kind.
// Interactive replies (search results, organize plans, range picks,
// duplicate groups) call back into App, which talks to the backend.

import { useState } from 'react';
import { Button } from '@astryxdesign/core/Button';

import type { ChatResponse, OrganizeMove, OrganizeRange } from '../../shared/types';
import { formatBytes, formatDate, getFileKind } from '../utils/fileTypes';
import { FileRow } from './FileRow';
import { DuplicatesBlock } from './DuplicateGroupCard';

export interface ChatMessageActions {
  onOpenFile: (path: string) => void;
  onOpenFolder: (path: string) => void;
  onPlanOrganize: (range: OrganizeRange) => void;
  onApplyOrganize: (plan: OrganizeMove[]) => void;
  onDuplicateResult: (text: string) => void;
}

interface ChatMessageProps {
  response: ChatResponse;
  actions: ChatMessageActions;
}

export const RANGES: Array<{ label: string; range: OrganizeRange }> = [
  { label: 'Today', range: { kind: 'today' } },
  { label: 'Yesterday', range: { kind: 'yesterday' } },
  { label: 'Last 3 days', range: { kind: 'lastDays', days: 3 } },
  { label: 'Last 7 days', range: { kind: 'lastDays', days: 7 } },
  { label: 'All', range: { kind: 'all' } },
];

function PlainText({ text }: { text: string }) {
  return <p className="dj-text">{text}</p>;
}

export function ChatMessage({ response, actions }: ChatMessageProps) {
  // An organize preview that the user cancelled stays visible as
  // cancelled text; nothing was moved.
  const [organizeCancelled, setOrganizeCancelled] = useState(false);

  switch (response.kind) {
    case 'message':
    case 'help':
      return <PlainText text={response.text} />;

    case 'search':
    case 'opened':
      return (
        <div>
          <PlainText text={response.text} />
          <div className="dj-cards">
            {response.results.map((result) => (
              <FileRow
                key={result.path}
                kind={getFileKind(result.name)}
                name={result.name}
                folder={result.folder}
                sizeText={result.size !== undefined ? formatBytes(result.size) : undefined}
                dateText={result.mtime ? formatDate(result.mtime) : undefined}
                snippet={result.snippet || undefined}
                actionLabel="Open"
                onAction={() => actions.onOpenFile(result.path)}
              />
            ))}
          </div>
        </div>
      );

    case 'summary':
      return (
        <div>
          <PlainText text={response.text} />
          <div className="dj-summary-file">{response.fileName}</div>
          <p className="dj-text">{response.summary}</p>
          <p className="dj-summary-note">{response.note}</p>
        </div>
      );

    case 'ask-range':
      return (
        <div>
          <PlainText text={response.text} />
          <div className="dj-row">
            {RANGES.map(({ label, range }) => (
              <Button
                key={label}
                label={label}
                variant="secondary"
                onClick={() => actions.onPlanOrganize(range)}
              />
            ))}
          </div>
        </div>
      );

    case 'organize-plan': {
      if (organizeCancelled) {
        return <PlainText text="Organize cancelled. Nothing was moved." />;
      }
      const shown = response.plan.slice(0, 20);
      const rest = response.plan.length - shown.length;
      return (
        <div>
          <PlainText text={response.text} />
          <div className="dj-cards">
            {shown.map((move) => (
              <FileRow
                key={move.old}
                kind={getFileKind(move.name)}
                name={move.name}
                folder={`${move.old} → ${move.new}`}
              />
            ))}
            {rest > 0 ? (
              <p className="dj-text dj-text-muted">and {rest} more</p>
            ) : null}
          </div>
          <div className="dj-row">
            <Button
              label="Yes, move them"
              variant="primary"
              onClick={() => actions.onApplyOrganize(response.plan)}
            />
            <Button
              label="Cancel"
              variant="ghost"
              onClick={() => setOrganizeCancelled(true)}
            />
          </div>
        </div>
      );
    }

    case 'organize-done':
      return (
        <div>
          <PlainText text={response.text} />
          {response.errors.length > 0 ? (
            <div className="dj-cards">
              {response.errors.map((error, i) => (
                <p className="dj-text" key={i}>
                  Could not move: {error}
                </p>
              ))}
            </div>
          ) : null}
          {response.logPath ? (
            <p className="dj-text dj-text-muted">Log: {response.logPath}</p>
          ) : null}
        </div>
      );

    case 'duplicates':
      return (
        <div>
          <PlainText text={response.text} />
          <div className="dj-cards">
            <DuplicatesBlock
              groups={response.groups}
              onResult={actions.onDuplicateResult}
            />
          </div>
        </div>
      );

    case 'folders':
      return (
        <div>
          <PlainText text={response.text} />
          <div className="dj-cards">
            {response.folders.map((folder) => (
              <FileRow
                key={folder.path}
                kind="folder"
                name={folder.name}
                folder={folder.path}
                actionLabel="Open folder"
                onAction={() => actions.onOpenFolder(folder.path)}
              />
            ))}
          </div>
        </div>
      );

    case 'duplicates-deleted':
    case 'duplicates-merged': {
      const lines = [response.text];
      if (response.errors.length > 0) {
        lines.push(`Could not finish ${response.errors.length}:`);
        response.errors.forEach((e) => lines.push(`- ${e}`));
      }
      return <PlainText text={lines.join('\n')} />;
    }

    default:
      return <PlainText text="DJ sent a reply I cannot show." />;
  }
}
