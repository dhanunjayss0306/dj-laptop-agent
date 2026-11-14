// DJ v5.4 — the status cards on the Command Center page. Three
// real cards, nothing invented: which capability layer is active
// and why (v5.3), what the index holds, and whether a model is
// actually running. Every number comes from DjStatus.

import { Badge } from '@astryxdesign/core/Badge';
import { Button } from '@astryxdesign/core/Button';
import { Card } from '@astryxdesign/core/Card';
import { StatusDot } from '@astryxdesign/core/StatusDot';

import type { DjStatus } from '../../shared/types';
import { capabilityBadge } from '../pages';
import { getEmbedderSource, getEmbedderState } from '../embedder';

interface StatusCardsProps {
  status: DjStatus | null;
  onRebuildIndex: () => void;
  onOpenFolders: () => void;
}

export function StatusCards({ status, onRebuildIndex, onOpenFolders }: StatusCardsProps) {
  const badge = capabilityBadge(status?.capability ?? null);
  const embedderState = status?.embedderState ?? getEmbedderState();
  const embedderSource = status?.embedderSource ?? getEmbedderSource();
  const searchMode =
    status == null ? 'loading status…' : status.vectorOk ? 'meaning search' : 'keyword search only';
  const embedderLabel =
    embedderState === 'ready'
      ? embedderSource === 'bundled'
        ? 'embedder ready (bundled model)'
        : embedderSource === 'downloaded'
          ? 'embedder ready (downloaded model)'
          : 'embedder ready'
      : embedderState === 'loading'
        ? 'embedder loading'
        : embedderState === 'unavailable'
          ? 'embedder not available'
          : 'embedder not started';
  const modelLine = status
    ? status.capability.local.available
      ? `Local model running: ${status.capability.local.name ?? 'yes'}`
      : 'Local model not running'
    : 'Local model: checking';
  const cloudLine = status
    ? status.capability.cloud.configured
      ? status.capability.cloud.valid === false
        ? 'Cloud key expired or invalid'
        : status.capability.cloud.valid === true
          ? 'Cloud key works'
          : 'Cloud key set, not checked yet'
      : 'No cloud key set'
    : 'Cloud: checking';

  return (
    <div className="dj-cards-grid">
      <Card>
        <div className="dj-stat-card">
          <div className="dj-stat-head">
            <span className="dj-stat-title">Capability</span>
            <StatusDot variant={badge.dot} label={badge.dotLabel} />
          </div>
          <div className="dj-stat-row">
            <Badge label={badge.label} variant={badge.variant} />
          </div>
          <p className="dj-stat-text">{status?.capability.message ?? 'checking layers…'}</p>
        </div>
      </Card>

      <Card>
        <div className="dj-stat-card">
          <div className="dj-stat-head">
            <span className="dj-stat-title">Index</span>
            <Badge label={searchMode} variant={status?.vectorOk ? 'success' : 'neutral'} />
          </div>
          <p className="dj-stat-value">
            {status ? status.filesIndexed : '—'}
            <span className="dj-stat-unit"> files in </span>
            {status ? status.foldersIndexed : '—'}
            <span className="dj-stat-unit"> folders</span>
          </p>
          <p className="dj-stat-text">{embedderLabel}</p>
          <div className="dj-stat-actions">
            <Button label="Rebuild index" variant="secondary" size="sm" onClick={onRebuildIndex} />
            <Button label="Folders" variant="secondary" size="sm" onClick={onOpenFolders} />
          </div>
        </div>
      </Card>

      <Card>
        <div className="dj-stat-card">
          <div className="dj-stat-head">
            <span className="dj-stat-title">Model</span>
          </div>
          <p className="dj-stat-text">{modelLine}</p>
          <p className="dj-stat-text">{cloudLine}</p>
          <p className="dj-stat-note">
            DJ works with no model and no key. A model or key only adds better answers.
          </p>
        </div>
      </Card>
    </div>
  );
}
