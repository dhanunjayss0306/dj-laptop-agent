// DJ v5.4 — the Memory page. Shows the v5.3 memory files,
// read-only: MEMORY.md (long-term facts) and the daily notes.
// Search filters the lines shown; nothing here writes to the
// files, and nothing is invented — an empty file shows an empty
// state instead of placeholder text.

import { useCallback, useEffect, useState } from 'react';
import { Card } from '@astryxdesign/core/Card';
import { EmptyState } from '@astryxdesign/core/EmptyState';
import { Skeleton } from '@astryxdesign/core/Skeleton';
import { Tab } from '@astryxdesign/core/TabList';
import { TabList } from '@astryxdesign/core/TabList';
import { TextInput } from '@astryxdesign/core/TextInput';

import type { MemoryContent } from '../../shared/types';
import { filterMemoryLines } from '../pages';

type MemoryTab = 'long' | 'daily';

export function MemoryPage() {
  const [content, setContent] = useState<MemoryContent | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [tab, setTab] = useState<MemoryTab>('long');
  const [query, setQuery] = useState('');

  const load = useCallback(async () => {
    setLoading(true);
    setError('');
    try {
      setContent(await window.dj.getMemory());
    } catch (err) {
      setError(`Could not read memory files: ${String(err)}`);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const longLines = content ? filterMemoryLines(content.memoryMd, query) : [];
  const longShown = longLines.filter((l) => l.trim().length > 0);
  const dailyShown = (content?.daily ?? []).map((d) => ({
    date: d.date,
    lines: filterMemoryLines(d.text, query).filter((l) => l.trim().length > 0),
  }));

  return (
    <div className="dj-page">
      <div className="dj-page-head">
        <h2 className="dj-page-title">Memory</h2>
      </div>
      <p className="dj-page-note">
        What DJ remembers, from plain Markdown files on this laptop. Read-only here.
      </p>

      <div className="dj-memory-search">
        <TextInput
          label="Search memory"
          isLabelHidden
          placeholder="Search memory..."
          value={query}
          onChange={(value) => setQuery(value)}
        />
      </div>

      <TabList value={tab} onChange={(value) => setTab(value as MemoryTab)} hasDivider>
        <Tab value="long" label="Long-term" />
        <Tab value="daily" label="Daily notes" />
      </TabList>

      {loading && !content ? (
        <div className="dj-cards-grid">
          <Skeleton width="100%" height={120} />
        </div>
      ) : null}

      {error ? <p className="dj-text">{error}</p> : null}

      {!loading && !error && tab === 'long' ? (
        longShown.length === 0 ? (
          <EmptyState
            title="No long-term memory yet"
            description={
              query
                ? 'Nothing in long-term memory matches that search.'
                : 'DJ has not saved any long-term facts yet. Facts get saved as you use DJ.'
            }
          />
        ) : (
          <Card>
            <div className="dj-memory-text">{longShown.join('\n')}</div>
          </Card>
        )
      ) : null}

      {!loading && !error && tab === 'daily' ? (
        dailyShown.length === 0 || dailyShown.every((d) => d.lines.length === 0) ? (
          <EmptyState
            title="No daily notes yet"
            description={
              query
                ? 'Nothing in the daily notes matches that search.'
                : 'DJ has not written any daily notes yet. Notes appear when something changes, like the capability layer.'
            }
          />
        ) : (
          dailyShown
            .filter((d) => d.lines.length > 0)
            .map((d) => (
              <Card key={d.date}>
                <div className="dj-stat-card">
                  <div className="dj-stat-title">{d.date}</div>
                  <div className="dj-memory-text">{d.lines.join('\n')}</div>
                </div>
              </Card>
            ))
        )
      ) : null}
    </div>
  );
}
