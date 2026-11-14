// DJ v5.4 — the app window, rebuilt on the Astryx AppShell: a
// top nav, a side nav with DJ's real sections, and a command
// palette (Ctrl+K). The chat is the Command Center page; Files,
// Duplicates, Organize, System, Memory, and Settings are real
// pages behind the same shell. Rules only, no AI: summaries are
// picked from the file itself, and the UI says so wherever a
// summary is shown (see ChatMessage, 'summary' kind).

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { AppShell } from '@astryxdesign/core/AppShell';
import { Badge } from '@astryxdesign/core/Badge';
import { Button } from '@astryxdesign/core/Button';
import { CommandPalette } from '@astryxdesign/core/CommandPalette';
import { ProgressBar } from '@astryxdesign/core/ProgressBar';
import { SideNav, SideNavHeading, SideNavItem, SideNavSection } from '@astryxdesign/core/SideNav';
import { StatusDot } from '@astryxdesign/core/StatusDot';
import { TextInput } from '@astryxdesign/core/TextInput';
import { useToast } from '@astryxdesign/core/Toast';
import { TopNav, TopNavHeading } from '@astryxdesign/core/TopNav';
import { createStaticSource } from '@astryxdesign/core/Typeahead';

import type {
  AppConfig,
  ChatResponse,
  DjStatus,
  IndexProgress,
  OrganizeMove,
  OrganizeRange,
  UpdateState,
} from '../shared/types';
import { ChatMessage } from './components/ChatMessage';
import { DuplicatesPage } from './components/DuplicatesPage';
import { FilesPage } from './components/FilesPage';
import { FoldersDialog } from './components/FoldersDialog';
import { MemoryPage } from './components/MemoryPage';
import { OrganizePage } from './components/OrganizePage';
import { SettingsPage } from './components/SettingsPage';
import { StatusCards } from './components/StatusCards';
import { SystemPage } from './components/SystemPage';
import { getEmbedderSource, getEmbedderState, reportEmbedderState } from './embedder';
import {
  PAGES,
  PALETTE_COMMANDS,
  capabilityBadge,
  findPaletteCommand,
  type PageId,
} from './pages';

interface DjMessage {
  id: number;
  role: 'user' | 'dj';
  text?: string;
  response?: ChatResponse;
}

const WELCOME_TEXT =
  "Hi, I'm DJ. I find your files on this laptop — by name or by what is inside them. " +
  'Try "find my Virun pitch", "open the frontend folder", "summarize my Virun pitch", ' +
  '"organize yesterday\'s Downloads", "find duplicates", or "open notepad". ' +
  'Summaries are picked from the file itself, no AI.';

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
  const [update, setUpdate] = useState<UpdateState | null>(null);
  const [page, setPage] = useState<PageId>('command');
  const [paletteOpen, setPaletteOpen] = useState(false);
  const chatEndRef = useRef<HTMLDivElement | null>(null);
  const toast = useToast();

  const pushDj = useCallback((response: ChatResponse) => {
    setMessages((prev) => [...prev, { id: nextId++, role: 'dj', response }]);
  }, []);

  const pushDjText = useCallback(
    (text: string) => {
      pushDj({ kind: 'message', text });
    },
    [pushDj],
  );

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

  // Startup: subscribe to index progress and update status, load
  // status/config, and open setup on first run (no index yet).
  // Guarded: if the built preload (dist) is older than this renderer
  // and lacks a subscription, the app must still load instead of
  // crashing to a blank screen. Run `npm run build` to refresh dist.
  useEffect(() => {
    const noop = (): void => {};
    const unsubscribeProgress =
      typeof window.dj.onIndexProgress === 'function'
        ? window.dj.onIndexProgress((p) => {
            setProgress(p);
            if (p.stage === 'done') {
              setBuilding(false);
            }
          })
        : noop;
    const unsubscribeUpdate =
      typeof window.dj.onUpdateStatus === 'function'
        ? window.dj.onUpdateStatus((s) => {
            setUpdate(s);
          })
        : noop;
    void (async () => {
      const s = await refreshStatus();
      if (s && !s.hasIndex) {
        setFoldersFirstRun(true);
        setFoldersOpen(true);
      }
    })();
    return () => {
      unsubscribeProgress();
      unsubscribeUpdate();
    };
  }, [refreshStatus]);

  // Keep the newest message visible.
  useEffect(() => {
    chatEndRef.current?.scrollIntoView({ behavior: 'auto', block: 'end' });
  }, [messages, busy, page]);

  // Ctrl+K (or Cmd+K) opens the command palette from anywhere.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') {
        e.preventDefault();
        setPaletteOpen(true);
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  const runBuildIndex = useCallback(async () => {
    setBuilding(true);
    setProgress(null);
    try {
      const counts = await window.dj.buildIndex();
      reportEmbedderState();
      pushDjText(
        `Index built: ${counts.files} files, ${counts.folders} folders, ${counts.embedded} with meaning search, ` +
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
      toast({ body: 'Folders saved. Rebuilding index.' });
      await runBuildIndex();
    },
    [pushDjText, runBuildIndex, toast],
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

  const handleOpenFolder = useCallback(
    async (path: string) => {
      try {
        const res = await window.dj.openFolder(path);
        pushDjText(res.message);
      } catch (err) {
        pushDjText(`Could not open that folder: ${String(err)}`);
      }
    },
    [pushDjText],
  );

  const openFoldersDialog = useCallback(() => {
    setFoldersFirstRun(false);
    setFoldersOpen(true);
  }, []);

  // Command palette: one static source for pages + actions. Picking
  // an item runs it — go to a page, or do the real action.
  const paletteSource = useMemo(
    () =>
      createStaticSource(
        PALETTE_COMMANDS.map((c) => ({
          id: c.id,
          label: c.label,
          auxiliaryData: { group: c.group },
        })),
        { keywords: (item) => findPaletteCommand(item.id)?.keywords ?? [] },
      ),
    [],
  );

  const runPaletteCommand = useCallback(
    (id: string) => {
      setPaletteOpen(false);
      const cmd = findPaletteCommand(id);
      if (!cmd) return;
      if (cmd.id.startsWith('page:')) {
        setPage(cmd.id.slice('page:'.length) as PageId);
        return;
      }
      switch (cmd.id) {
        case 'action:rebuild-index':
          void runBuildIndex();
          break;
        case 'action:folders':
          openFoldersDialog();
          break;
        case 'action:find-duplicates':
          setPage('duplicates');
          break;
        case 'action:organize-downloads':
          setPage('organize');
          break;
        case 'action:refresh-status':
          void refreshStatus();
          toast({ body: 'Status refreshed.' });
          break;
        default:
          break;
      }
    },
    [openFoldersDialog, refreshStatus, runBuildIndex, toast],
  );

  const embedderState = status?.embedderState ?? getEmbedderState();
  const embedderSource = status?.embedderSource ?? getEmbedderSource();
  // v5.3: which capability layer is active and why. When the model
  // is gone or the key expired this says so plainly, e.g.
  // "Core only: cloud key expired, local model not running".
  const capabilityMessage = status?.capability?.message ?? 'checking layers…';
  const capability = capabilityBadge(status?.capability ?? null);
  const searchMode =
    status == null
      ? 'loading status…'
      : status.vectorOk
        ? 'meaning search'
        : 'keyword search only';
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

  const progressValue =
    progress && progress.total > 0
      ? Math.round((progress.done / progress.total) * 100)
      : 0;

  return (
    <AppShell
      topNav={
        <TopNav
          heading={<TopNavHeading heading="DJ" />}
          endContent={
            <>
              <StatusDot variant={capability.dot} label={capability.dotLabel} />
              <Badge label={capability.label} variant={capability.variant} />
              <Button label="Search" variant="ghost" onClick={() => setPaletteOpen(true)} />
            </>
          }
        />
      }
      sideNav={
        <SideNav header={<SideNavHeading heading="DJ" />}>
          <SideNavSection title="DJ">
            {PAGES.map((p) => (
              <SideNavItem
                key={p.id}
                label={p.label}
                isSelected={page === p.id}
                onClick={() => setPage(p.id)}
              />
            ))}
          </SideNavSection>
          <SideNavSection title="Status">
            <p className="dj-nav-status">
              {status ? `${status.filesIndexed} files indexed` : 'loading status…'}
            </p>
            <p className="dj-nav-status">{searchMode}</p>
            <p className="dj-nav-status">{embedderLabel}</p>
          </SideNavSection>
        </SideNav>
      }
    >
      <div className="dj-page-shell">
        {status?.indexStale ? (
          <div className="dj-stale">
            The search index was built with an older format — Rebuild index to use meaning
            search.
          </div>
        ) : null}

        {update?.status === 'ready' ? (
          <div className="dj-update">{update.message}</div>
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

        {page === 'command' ? (
          <div className="dj-command-page">
            <StatusCards
              status={status}
              onRebuildIndex={() => void runBuildIndex()}
              onOpenFolders={openFoldersDialog}
            />
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
                          onOpenFolder: (path) => void handleOpenFolder(path),
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
                  placeholder="Find a file, open a folder, organize Downloads..."
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
          </div>
        ) : null}

        {page === 'files' ? (
          <FilesPage
            onOpenFile={(path) => void handleOpenFile(path)}
            onRebuildIndex={() => void runBuildIndex()}
          />
        ) : null}

        {page === 'duplicates' ? (
          <DuplicatesPage onResult={(text) => pushDjText(text)} />
        ) : null}

        {page === 'organize' ? <OrganizePage /> : null}

        {page === 'system' ? <SystemPage /> : null}

        {page === 'memory' ? <MemoryPage /> : null}

        {page === 'settings' ? (
          <SettingsPage
            status={status}
            config={config}
            onOpenFolders={openFoldersDialog}
            onRebuildIndex={() => void runBuildIndex()}
            onRefreshStatus={() => void refreshStatus()}
          />
        ) : null}

        <p className="dj-capability-line">{capabilityMessage}</p>
      </div>

      <CommandPalette
        isOpen={paletteOpen}
        onOpenChange={(open) => setPaletteOpen(open)}
        searchSource={paletteSource}
        onValueChange={(value) => runPaletteCommand(value)}
        emptySearchText="No matching page or action"
        emptyBootstrapText="Type to search pages and actions"
      />

      <FoldersDialog
        isOpen={foldersOpen}
        isFirstRun={foldersFirstRun}
        config={config}
        onOpenChange={(open) => setFoldersOpen(open)}
        onSave={(next) => void handleSaveFolders(next)}
      />
    </AppShell>
  );
}
