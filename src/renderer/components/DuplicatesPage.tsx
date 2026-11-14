// DJ v5.4 — the Duplicates page. Finds extra copies in the
// indexed folders and shows them in the same cards the chat uses,
// with the same confirm-before-delete rule. An empty result shows
// an empty state, not a blank page.

import { useCallback, useEffect, useState } from 'react';
import { Button } from '@astryxdesign/core/Button';
import { EmptyState } from '@astryxdesign/core/EmptyState';
import { Skeleton } from '@astryxdesign/core/Skeleton';

import type { DuplicateGroup } from '../../shared/types';
import { DuplicatesBlock } from './DuplicateGroupCard';

interface DuplicatesPageProps {
  onResult: (text: string) => void;
}

export function DuplicatesPage({ onResult }: DuplicatesPageProps) {
  const [groups, setGroups] = useState<DuplicateGroup[] | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  const load = useCallback(async () => {
    setLoading(true);
    setError('');
    try {
      setGroups(await window.dj.findDuplicates());
    } catch (err) {
      setError(`Could not look for duplicates: ${String(err)}`);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  return (
    <div className="dj-page">
      <div className="dj-page-head">
        <h2 className="dj-page-title">Duplicates</h2>
        <Button
          label="Find duplicates"
          variant="secondary"
          isDisabled={loading}
          onClick={() => void load()}
        />
      </div>
      <p className="dj-page-note">
        Extra copies in your folders. The first copy in each group is always kept.
      </p>

      {loading && groups === null ? (
        <div className="dj-cards">
          <Skeleton width="100%" height={120} />
          <Skeleton width="100%" height={120} />
        </div>
      ) : null}

      {error ? <p className="dj-text">{error}</p> : null}

      {!loading && !error && groups !== null && groups.length === 0 ? (
        <EmptyState
          title="No duplicates found"
          description="I found no extra copies in your folders."
          actions={
            <Button label="Check again" variant="secondary" onClick={() => void load()} />
          }
        />
      ) : null}

      {!loading && !error && groups !== null && groups.length > 0 ? (
        <div className="dj-cards">
          <p className="dj-text dj-text-muted">
            {groups.length} group(s) of extra copies
          </p>
          <DuplicatesBlock groups={groups} onResult={onResult} />
        </div>
      ) : null}
    </div>
  );
}
