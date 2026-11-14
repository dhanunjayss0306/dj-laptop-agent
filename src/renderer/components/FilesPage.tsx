// DJ v5.4 — the Files page. Search by name or by what is inside
// the files, using the same search the chat uses. Results are the
// real Explorer-style rows with a working Open button. No results
// shows an empty state with a real action (rebuild the index).

import { useState } from 'react';
import { Button } from '@astryxdesign/core/Button';
import { EmptyState } from '@astryxdesign/core/EmptyState';
import { TextInput } from '@astryxdesign/core/TextInput';

import type { SearchResult } from '../../shared/types';
import { formatBytes, formatDate, getFileKind } from '../utils/fileTypes';
import { FileRow } from './FileRow';

interface FilesPageProps {
  onOpenFile: (path: string) => void;
  onRebuildIndex: () => void;
}

export function FilesPage({ onOpenFile, onRebuildIndex }: FilesPageProps) {
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<SearchResult[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [searched, setSearched] = useState('');

  const runSearch = async (q: string) => {
    const text = q.trim();
    if (!text || busy) return;
    setBusy(true);
    try {
      setResults(await window.dj.search(text));
      setSearched(text);
    } catch {
      setResults([]);
      setSearched(text);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="dj-page">
      <div className="dj-page-head">
        <h2 className="dj-page-title">Files</h2>
      </div>
      <form
        className="dj-search-form"
        onSubmit={(e) => {
          e.preventDefault();
          void runSearch(query);
        }}
      >
        <div className="dj-search-input">
          <TextInput
            label="Search files"
            isLabelHidden
            placeholder="Find a file by name or by what is inside it..."
            value={query}
            onChange={(value) => setQuery(value)}
            isDisabled={busy}
          />
        </div>
        <Button
          label="Search"
          variant="primary"
          type="submit"
          isDisabled={busy || query.trim() === ''}
        />
      </form>

      {results !== null && results.length === 0 ? (
        <EmptyState
          title="No files found"
          description={`Nothing about '${searched}' in your folders. Try different words, or rebuild the index if you added files recently.`}
          actions={
            <Button label="Rebuild index" variant="secondary" onClick={onRebuildIndex} />
          }
        />
      ) : null}

      {results !== null && results.length > 0 ? (
        <div className="dj-cards">
          <p className="dj-text dj-text-muted">
            {results.length} file(s) about &lsquo;{searched}&rsquo;
          </p>
          {results.map((result) => (
            <FileRow
              key={result.path}
              kind={getFileKind(result.name)}
              name={result.name}
              folder={result.folder}
              sizeText={result.size !== undefined ? formatBytes(result.size) : undefined}
              dateText={result.mtime ? formatDate(result.mtime) : undefined}
              snippet={result.snippet || undefined}
              actionLabel="Open"
              onAction={() => onOpenFile(result.path)}
            />
          ))}
        </div>
      ) : null}
    </div>
  );
}
