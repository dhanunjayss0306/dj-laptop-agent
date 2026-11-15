// DJ v5.4 — the Settings page. Folders DJ searches, the
// capability layer with a refresh button, and the embedder state.
// Every button does something real; nothing here is a placeholder.

import { Button } from '@astryxdesign/core/Button';
import { Card } from '@astryxdesign/core/Card';
import { Switch } from '@astryxdesign/core/Switch';

import type { AppConfig, DjStatus } from '../../shared/types';
import { capabilityBadge } from '../pages';
import { getEmbedderSource, getEmbedderState } from '../embedder';

interface SettingsPageProps {
  status: DjStatus | null;
  config: AppConfig | null;
  /** v5.6: effective "start at login" value. */
  startAtLogin: boolean;
  onToggleStartAtLogin: (enabled: boolean) => void;
  onOpenFolders: () => void;
  onRebuildIndex: () => void;
  onRefreshStatus: () => void;
}

export function SettingsPage({
  status,
  config,
  startAtLogin,
  onToggleStartAtLogin,
  onOpenFolders,
  onRebuildIndex,
  onRefreshStatus,
}: SettingsPageProps) {
  const badge = capabilityBadge(status?.capability ?? null);
  const enabled = config?.folders.filter((f) => f.enabled) ?? [];
  const embedderState = status?.embedderState ?? getEmbedderState();
  const embedderSource = status?.embedderSource ?? getEmbedderSource();

  return (
    <div className="dj-page">
      <div className="dj-page-head">
        <h2 className="dj-page-title">Settings</h2>
      </div>

      <Card>
        <div className="dj-stat-card">
          <div className="dj-stat-title">Folders DJ searches</div>
          {enabled.length === 0 ? (
            <p className="dj-stat-text">No folders enabled yet.</p>
          ) : (
            enabled.map((f) => (
              <p className="dj-stat-text" key={f.path}>
                {f.path}
              </p>
            ))
          )}
          <div className="dj-stat-actions">
            <Button label="Folders" variant="secondary" size="sm" onClick={onOpenFolders} />
            <Button label="Rebuild index" variant="secondary" size="sm" onClick={onRebuildIndex} />
          </div>
        </div>
      </Card>

      <Card>
        <div className="dj-stat-card">
          <div className="dj-stat-title">Capability</div>
          <p className="dj-stat-text">
            {badge.label}: {status?.capability.message ?? 'checking layers…'}
          </p>
          <p className="dj-stat-text">
            Embedder: {embedderState}
            {embedderState === 'ready' ? ` (${embedderSource} model)` : ''}
          </p>
          <div className="dj-stat-actions">
            <Button label="Refresh status" variant="secondary" size="sm" onClick={onRefreshStatus} />
          </div>
        </div>
      </Card>

      <Card>
        <div className="dj-stat-card">
          <div className="dj-stat-title">Always running</div>
          <Switch
            label="Start DJ when Windows starts"
            description="DJ opens on its own when you sign in, and keeps running in the tray when you close its window."
            value={startAtLogin}
            onChange={(checked) => onToggleStartAtLogin(checked)}
          />
          {status?.hasTray ? (
            <p className="dj-stat-text">
              To fully quit DJ, right-click the tray icon and choose Quit DJ.
            </p>
          ) : null}
        </div>
      </Card>

      <Card>
        <div className="dj-stat-card">
          <div className="dj-stat-title">About DJ</div>
          <p className="dj-stat-text">
            DJ runs on this laptop only. Files never leave the laptop, and DJ works with no model
            and no API key.
          </p>
        </div>
      </Card>
    </div>
  );
}
