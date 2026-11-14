// DJ v5.4 — the System page. Real numbers only, read in the main
// process from Node's os module: CPU use (two samples 500 ms
// apart), RAM total and free, uptime, core count, platform. Each
// number is labelled with its source. Disk usage is left out: Node
// has no reliable built-in call for it on Windows, and DJ never
// invents a number.

import { useCallback, useEffect, useState } from 'react';
import { Button } from '@astryxdesign/core/Button';
import { Card } from '@astryxdesign/core/Card';
import { Skeleton } from '@astryxdesign/core/Skeleton';

import type { SystemStats } from '../../shared/types';
import { formatUptime } from '../pages';
import { formatBytes } from '../utils/fileTypes';

function StatRow({ label, value, source }: { label: string; value: string; source: string }) {
  return (
    <div className="dj-stat-row-line">
      <div>
        <div className="dj-stat-label">{label}</div>
        <div className="dj-stat-value">{value}</div>
        <div className="dj-stat-source">Source: {source}</div>
      </div>
    </div>
  );
}

export function SystemPage() {
  const [stats, setStats] = useState<SystemStats | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  const load = useCallback(async () => {
    setLoading(true);
    setError('');
    try {
      setStats(await window.dj.getSystemStats());
    } catch (err) {
      setError(`Could not read system numbers: ${String(err)}`);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const usedMem = stats ? stats.totalMemBytes - stats.freeMemBytes : 0;
  const usedPct =
    stats && stats.totalMemBytes > 0
      ? Math.round((usedMem / stats.totalMemBytes) * 100)
      : null;

  return (
    <div className="dj-page">
      <div className="dj-page-head">
        <h2 className="dj-page-title">System</h2>
        <Button label="Refresh" variant="secondary" isDisabled={loading} onClick={() => void load()} />
      </div>
      <p className="dj-page-note">
        Numbers read from this laptop when you open this page or press Refresh. Nothing here is
        estimated.
      </p>

      {loading && !stats ? (
        <div className="dj-cards-grid">
          <Skeleton width="100%" height={120} />
          <Skeleton width="100%" height={120} />
          <Skeleton width="100%" height={120} />
        </div>
      ) : null}

      {error ? (
        <Card>
          <div className="dj-stat-card">
            <p className="dj-stat-text">{error}</p>
            <Button label="Try again" variant="secondary" size="sm" onClick={() => void load()} />
          </div>
        </Card>
      ) : null}

      {stats ? (
        <div className="dj-cards-grid">
          <Card>
            <div className="dj-stat-card">
              <StatRow
                label="CPU use"
                value={stats.cpuPercent === null ? 'Not available' : `${stats.cpuPercent}%`}
                source="Node os.cpus(), two samples 500 ms apart"
              />
              <p className="dj-stat-text">{stats.cpuCores} cores</p>
            </div>
          </Card>
          <Card>
            <div className="dj-stat-card">
              <StatRow
                label="Memory used"
                value={`${formatBytes(usedMem)} of ${formatBytes(stats.totalMemBytes)}${usedPct === null ? '' : ` (${usedPct}%)`}`}
                source="Node os.totalmem() and os.freemem()"
              />
              <p className="dj-stat-text">{formatBytes(stats.freeMemBytes)} free</p>
            </div>
          </Card>
          <Card>
            <div className="dj-stat-card">
              <StatRow
                label="Uptime"
                value={formatUptime(stats.uptimeSeconds)}
                source="Node os.uptime()"
              />
              <p className="dj-stat-text">{stats.platform}</p>
              <p className="dj-stat-source">
                Checked at {new Date(stats.checkedAt).toLocaleTimeString()}
              </p>
            </div>
          </Card>
        </div>
      ) : null}
    </div>
  );
}
