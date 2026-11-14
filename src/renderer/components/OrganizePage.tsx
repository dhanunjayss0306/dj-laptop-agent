// DJ v5.4 — the Organize page. Pick a range, see the plan as a
// table of real moves, then say Yes or Cancel. Nothing moves until
// you say Yes, and the result names what actually moved.

import { useState } from 'react';
import { Button } from '@astryxdesign/core/Button';
import { Card } from '@astryxdesign/core/Card';
import { EmptyState } from '@astryxdesign/core/EmptyState';
import { Table, proportional } from '@astryxdesign/core/Table';

import type { ChatResponse, OrganizeMove } from '../../shared/types';
import { RANGES } from './ChatMessage';

const COLUMNS = [
  { key: 'file', header: 'File', width: proportional(1) },
  { key: 'from', header: 'Move from', width: proportional(2) },
  { key: 'to', header: 'Move to', width: proportional(2) },
  { key: 'folder', header: 'Folder', width: proportional(1) },
];

export function OrganizePage() {
  const [plan, setPlan] = useState<ChatResponse | null>(null);
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState('');

  const planFor = async (range: (typeof RANGES)[number]['range']) => {
    setBusy(true);
    setResult('');
    try {
      setPlan(await window.dj.planOrganize(range));
    } catch (err) {
      setPlan({ kind: 'message', text: `Could not plan the organize: ${String(err)}` });
    } finally {
      setBusy(false);
    }
  };

  const applyPlan = async (moves: OrganizeMove[]) => {
    setBusy(true);
    try {
      const res = await window.dj.applyOrganize(moves);
      setResult(res.text);
      setPlan(null);
    } catch (err) {
      setResult(`Could not move those files: ${String(err)}`);
    } finally {
      setBusy(false);
    }
  };

  const rows =
    plan?.kind === 'organize-plan'
      ? plan.plan.map((m) => ({ file: m.name, from: m.old, to: m.new, folder: m.folder }))
      : [];

  return (
    <div className="dj-page">
      <div className="dj-page-head">
        <h2 className="dj-page-title">Organize</h2>
      </div>
      <p className="dj-page-note">
        Sort Downloads into folders by when files were added. Nothing moves until you say Yes.
      </p>

      <div className="dj-row">
        {RANGES.map(({ label, range }) => (
          <Button
            key={label}
            label={label}
            variant="secondary"
            isDisabled={busy}
            onClick={() => void planFor(range)}
          />
        ))}
      </div>

      {result ? (
        <Card>
          <div className="dj-stat-card">
            <p className="dj-stat-text">{result}</p>
          </div>
        </Card>
      ) : null}

      {plan?.kind === 'message' ? (
        <EmptyState title="Nothing to organize" description={plan.text} />
      ) : null}

      {plan?.kind === 'organize-plan' ? (
        <div className="dj-cards">
          <p className="dj-text">{plan.text}</p>
          <Table data={rows} columns={COLUMNS} />
          <div className="dj-row">
            <Button
              label="Yes, move them"
              variant="primary"
              isDisabled={busy}
              onClick={() => void applyPlan(plan.plan)}
            />
            <Button label="Cancel" variant="ghost" isDisabled={busy} onClick={() => setPlan(null)} />
          </div>
        </div>
      ) : null}
    </div>
  );
}
