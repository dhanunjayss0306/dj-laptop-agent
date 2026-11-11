// DJ v3 — the app window. A single-page chat: ask DJ to find, open,
// summarize, organize, or de-duplicate files. Rules only, no AI:
// summaries are picked from the file itself, and the UI says so
// wherever a summary is shown (see ChatMessage, 'summary' kind).

import { useCallback, useEffect, useRef, useState } from 'react';
import { Button } from '@astryxdesign/core/Button';
import { ProgressBar } from '@astryxdesign/core/ProgressBar';
import { TextInput } from '@astryxdesign/core/TextInput';

import type {
  AppConfig,
  ChatResponse,
  DjStatus,
  IndexProgress,
  OrganizeMove,
  OrganizeRange,
} from '../shared/types';
import { ChatMessage } from './components/ChatMessage';
import { FoldersDialog } from './components/FoldersDialog';
import { getEmbedderState, reportEmbedderState } from './embedder';

interface DjMessage {
  id: number;
  role: 'user' | 'dj';
  text?: string;
  response?: ChatResponse;
}

const WELCOME_TEXT =
  "Hi, I'm DJ. I find your files on this laptop — by name or by what is inside them. " +
  'Try "find my Virun pitch", "summarize my Virun pitch", "organize yesterday\'s Downloads", ' +
  '"find duplicates", or "open notepad". Summaries are picked from the file itself, no AI.';

let nextId = 1;

export default function App() {
  const [status, setStatus] = useState<DjStatus | null>(null);
  const [config, setConfig] = useState<AppConfig | null>(null);
  const [messages, setMessages] = useState<DjMessage[]>([
    { id: 0, role: 'dj', text: WELCOME_TEXT },
  ]);
  const [input, setInput] = useState('');
  const [busy, setBusy] = useState(false);
  const [building, setBuilding] = useState(false);
  const [progress, setProgress] = useState<IndexProgress | null>(null);
  const [foldersOpen, setFoldersOpen] = useState(false);
  const [foldersFirstRun, setFoldersFirstRun] = useState(false);
  const chatEndRef = useRef<HTMLDivElement | null>(null);

  const pushDj = useCallback((response: ChatResponse) => {
    setMessages((prev) => [...prev, { id: nextId++, role: 'dj', response }]);
  }, []);

  const pushDjText = useCallback((text: string) => {
    pushDj({ kind: 'message', text });
  }, [pushDj]);

  const refreshStatus = useCallback(async () => {
    try {
      const s = await window.dj.getStatus();
      setStatus(s);
      setConfig(s.config);
      return s;
    } catch {
      return null;
    }
  }, []);

  // Startup: subscribe to index progress, load status/config, and
  // open setup on first run (no index yet).
  useEffect(() => {
    const unsubscribe = window.dj.onIndexProgress((p) => {
      setProgress(p);
      if (p.stage === 'done') {
        setBuilding(false);
      }
    });
    void (async () => {
      const s = await refreshStatus();
      if (s && !s.hasIndex) {
        setFoldersFirstRun(true);
        setFoldersOpen(true);
      }
    })();
    return unsubscribe;
  }, [refreshStatus]);

  // Keep the newest message visible.
  useEffect(() => {
    chatEndRef.current?.scrollIntoView({ behavior: 'auto', block: 'end' });
  }, [messages, busy]);

  const runBuildIndex = useCallback(async () => {
    setBuilding(true);
    setProgress(null);
    try {
      const counts = await window.dj.buildIndex();
      reportEmbedderState();
      pushDjText(
        `Index built: ${counts.files} files, ${counts.embedded} with meaning search, ` +
          `${counts.keywordOnly} keyword only` +
          (counts.skipped > 0 ? `, ${counts.skipped} skipped` : '') +
          (counts.errors > 0 ? `, ${counts.errors} errors` : '') +
          `. Took ${counts.seconds}s.`,
      );
    } catch (err) {
      pushDjText(`Index build failed: ${String(err)}`);
    } finally {
      setBuilding(false);
      await refreshStatus();
    }
  }, [pushDjText, refreshStatus]);

  const handleSaveFolders = useCallback(
    async (next: AppConfig) => {
      try {
        const saved = await window.dj.saveConfig(next);
        setConfig(saved);
      } catch (err) {
        pushDjText(`Could not save folders: ${String(err)}`);
        return;
      }
      setFoldersOpen(false);
      setFoldersFirstRun(false);
      await runBuildIndex();
    },
    [pushDjText, runBuildIndex],
  );

  const handleSend = useCallback(
    async (raw: string) => {
      const text = raw.trim();
      if (!text || busy) return;
      setMessages((prev) => [...prev, { id: nextId++, role: 'user', text }]);
      setInput('');
      setBusy(true);
      try {
        const response = await window.dj.send(text);
        pushDj(response);
      } catch (err) {
        pushDjText(`Something went wrong: ${String(err)}`);
      } finally {
        setBusy(false);
        void refreshStatus();
      }
    },
    [busy, pushDj, pushDjText, refreshStatus],
  );

  const handlePlanOrganize = useCallback(
    async (range: OrganizeRange) => {
      setBusy(true);
      try {
        const response = await window.dj.planOrganize(range);
        pushDj(response);
      } catch (err) {
        pushDjText(`Could not plan the organize: ${String(err)}`);
      } finally {
        setBusy(false);
      }
    },
    [pushDj, pushDjText],
  );

  const handleApplyOrganize = useCallback(
    async (plan: OrganizeMove[]) => {
      setBusy(true);
      try {
        const response = await window.dj.applyOrganize(plan);
        pushDj(response);
      } catch (err) {
        pushDjText(`Could not move those files: ${String(err)}`);
      } finally {
        setBusy(false);
        void refreshStatus();
      }
    },
    [pushDj, pushDjText, refreshStatus],
  );

  const handleOpenFile = useCallback(
    async (path: string) => {
      try {
        const res = await window.dj.openFile(path);
        pushDjText(res.message);
      } catch (err) {
        pushDjText(`Could not open that file: ${String(err)}`);
      }
    },
    [pushDjText],
  );

  const embedderState = status?.embedderState ?? getEmbedderState();
  const searchMode =
    status == null
      ? 'loading status…'
      : status.vectorOk
        ? 'meaning search'
        : 'keyword search only';
  const embedderLabel =
    embedderState === 'ready'
      ? 'embedder ready'
      : embedderState === 'loading'
        ? 'embedder loading'
        : embedderState === 'unavailable'
          ? 'embedder not available'
          : 'embedder not started';

  const progressValue =
    progress && progress.total > 0
      ? Math.round((progress.done / progress.total) * 100)
      : 0;

  return (
    <div className="dj-app">
      <header className="dj-header">
        <h1 className="dj-title">DJ</h1>
        <span className="dj-subtitle">your files, found</span>
        <div className="dj-header-actions">
          <Button
            label="Folders"
            variant="secondary"
            onClick={() => {
              setFoldersFirstRun(false);
              setFoldersOpen(true);
            }}
          />
          <Button
            label="Rebuild index"
            variant="secondary"
            isDisabled={building}
            onClick={() => void runBuildIndex()}
          />
        </div>
      </header>

      <div className="dj-statusbar">
        <span>
          <strong>{status ? status.filesIndexed : '—'}</strong> files indexed
        </span>
        <span>{searchMode}</span>
        <span>{embedderLabel}</span>
      </div>

      {status?.indexStale ? (
        <div className="dj-stale">
          The search index was built with an older format — Rebuild index to use meaning
          search.
        </div>
      ) : null}

      {(building || (progress && progress.stage !== 'done')) && (
        <div className="dj-progress">
          {progress?.message ? (
            <p className="dj-progress-message">{progress.message}</p>
          ) : null}
          <ProgressBar
            label="Building index"
            value={progressValue}
            max={100}
            hasValueLabel
            isIndeterminate={!progress || progress.total === 0}
          />
        </div>
      )}

      <main className="dj-chat">
        {messages.map((msg) =>
          msg.role === 'user' ? (
            <div className="dj-msg dj-msg-user" key={msg.id}>
              <p className="dj-text">{msg.text}</p>
            </div>
          ) : (
            <div className="dj-msg dj-msg-dj" key={msg.id}>
              {msg.response ? (
                <ChatMessage
                  response={msg.response}
                  actions={{
                    onOpenFile: (path) => void handleOpenFile(path),
                    onPlanOrganize: (range) => void handlePlanOrganize(range),
                    onApplyOrganize: (plan) => void handleApplyOrganize(plan),
                    onDuplicateResult: (text) => pushDjText(text),
                  }}
                />
              ) : (
                <p className="dj-text">{msg.text}</p>
              )}
            </div>
          ),
        )}
        {busy ? <div className="dj-working">DJ is working...</div> : null}
        <div ref={chatEndRef} />
      </main>

      <form
        className="dj-composer"
        onSubmit={(e) => {
          e.preventDefault();
          void handleSend(input);
        }}
      >
        <div className="dj-composer-input">
          <TextInput
            label="Message DJ"
            isLabelHidden
            placeholder="Find a file, summarize one, organize Downloads..."
            value={input}
            onChange={(value) => setInput(value)}
            isDisabled={busy}
          />
        </div>
        <Button
          label="Send"
          variant="primary"
          type="submit"
          isDisabled={busy || input.trim() === ''}
        />
      </form>

      <FoldersDialog
        isOpen={foldersOpen}
        isFirstRun={foldersFirstRun}
        config={config}
        onOpenChange={(open) => setFoldersOpen(open)}
        onSave={(next) => void handleSaveFolders(next)}
      />
    </div>
  );
}
