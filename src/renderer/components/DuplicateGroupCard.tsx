// DJ v3 — duplicate groups: pick extra copies to delete (to the Recycle
// Bin, after confirmation) or merge a whole group into one folder.
// The first file in every group is the keeper: it is never deletable.

import { useState } from 'react';
import { AlertDialog } from '@astryxdesign/core/AlertDialog';
import { Button } from '@astryxdesign/core/Button';
import { Card } from '@astryxdesign/core/Card';
import { CheckboxInput } from '@astryxdesign/core/CheckboxInput';
import { Dialog, DialogHeader } from '@astryxdesign/core/Dialog';
import { TextInput } from '@astryxdesign/core/TextInput';

import type { DuplicateGroup } from '../../shared/types';
import { formatBytes, getFileKind } from '../utils/fileTypes';
import { FileTypeIcon } from './FileRow';

const MERGE_TARGET_DEFAULT = 'C:\\Users\\dhanu\\Downloads\\Merged';

interface GroupCardProps {
  group: DuplicateGroup;
  onResult: (text: string) => void;
  onGroupsChanged: (groups: DuplicateGroup[]) => void;
}

function GroupCard({ group, onResult, onGroupsChanged }: GroupCardProps) {
  // Paths (not the keeper) ticked for deletion.
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [confirmOpen, setConfirmOpen] = useState(false);
  const [mergeOpen, setMergeOpen] = useState(false);
  const [mergeTarget, setMergeTarget] = useState(MERGE_TARGET_DEFAULT);
  const [working, setWorking] = useState(false);

  const keeper = group.files[0];
  const copies = group.files.slice(1);
  const allPaths = group.files.map((f) => f.path);

  const toggle = (path: string, checked: boolean) => {
    setSelected((prev) => {
      const next = new Set(prev);
      if (checked) {
        next.add(path);
      } else {
        next.delete(path);
      }
      return next;
    });
  };

  const refreshGroups = async () => {
    try {
      const groups = await window.dj.findDuplicates();
      onGroupsChanged(groups);
    } catch {
      // Keep the current list if the refresh fails; the result text
      // already told the user what happened.
    }
  };

  const handleDelete = async () => {
    const paths = [...selected];
    if (paths.length === 0) return;
    setWorking(true);
    setConfirmOpen(false);
    try {
      const res = await window.dj.deleteDuplicates(paths);
      const lines = [`Deleted ${res.deleted.length} copie(s) to the Recycle Bin.`];
      if (res.errors.length > 0) {
        lines.push(`Could not delete ${res.errors.length}:`);
        res.errors.forEach((e) => lines.push(`- ${e}`));
      }
      if (res.logPath) lines.push(`Log: ${res.logPath}`);
      onResult(lines.join('\n'));
      setSelected(new Set());
      await refreshGroups();
    } catch (err) {
      onResult(`Could not delete those copies: ${String(err)}`);
    } finally {
      setWorking(false);
    }
  };

  const handleMerge = async () => {
    const target = mergeTarget.trim();
    if (!target) return;
    setWorking(true);
    setMergeOpen(false);
    try {
      const res = await window.dj.mergeDuplicates(allPaths, target);
      const lines = [`Moved ${res.moved.length} file(s) into ${target}.`];
      if (res.errors.length > 0) {
        lines.push(`Could not move ${res.errors.length}:`);
        res.errors.forEach((e) => lines.push(`- ${e}`));
      }
      onResult(lines.join('\n'));
      await refreshGroups();
    } catch (err) {
      onResult(`Could not merge those copies: ${String(err)}`);
    } finally {
      setWorking(false);
    }
  };

  return (
    <Card>
      <div className="dj-dup-card">
        <div className="dj-dup-header">
          {keeper ? keeper.name : 'Files'} — {group.sizeText}, {group.files.length} copies,{' '}
          {formatBytes(group.wasted)} wasted
        </div>

        <div>
          {keeper && (
            <div className="dj-file-row" key={keeper.path}>
              <span className="dj-file-icon">
                <FileTypeIcon kind={getFileKind(keeper.name)} label={keeper.name} />
              </span>
              <div className="dj-file-main">
                <div className="dj-file-name">{keeper.name}</div>
                <div className="dj-file-path">
                  {keeper.folder}
                  {keeper.mtime ? ` — ${keeper.mtime}` : ''}
                </div>
              </div>
              <div className="dj-file-meta">
                <span>{group.sizeText}</span>
              </div>
              <span className="dj-keep">keep</span>
            </div>
          )}
          {copies.map((file) => (
            <div className="dj-file-row" key={file.path}>
              <span className="dj-file-icon">
                <FileTypeIcon kind={getFileKind(file.name)} label={file.name} />
              </span>
              <div className="dj-file-main">
                <div className="dj-file-name">{file.name}</div>
                <div className="dj-file-path">
                  {file.folder}
                  {file.mtime ? ` — ${file.mtime}` : ''}
                </div>
              </div>
              <div className="dj-file-meta">
                <span>{group.sizeText}</span>
              </div>
              <CheckboxInput
                label="Delete"
                value={selected.has(file.path)}
                onChange={(checked) => toggle(file.path, checked)}
              />
            </div>
          ))}
        </div>

        <div className="dj-dup-actions">
          <Button
            label="Delete selected copies"
            variant="destructive"
            isDisabled={selected.size === 0 || working}
            onClick={() => setConfirmOpen(true)}
          />
          <Button
            label="Merge into one folder"
            variant="secondary"
            isDisabled={working}
            onClick={() => {
              setMergeTarget(MERGE_TARGET_DEFAULT);
              setMergeOpen(true);
            }}
          />
        </div>

        <AlertDialog
          isOpen={confirmOpen}
          onOpenChange={(open) => setConfirmOpen(open)}
          title="Delete these copies?"
          description="These copies go to the Recycle Bin. The first copy is kept. Are you sure?"
          actionLabel="Delete copies"
          actionVariant="destructive"
          onAction={() => void handleDelete()}
        />

        <Dialog
          isOpen={mergeOpen}
          onOpenChange={(open) => setMergeOpen(open)}
          purpose="form"
          width={480}
        >
          <DialogHeader
            title="Merge into one folder"
            onOpenChange={(open) => setMergeOpen(open)}
          />
          <div className="dj-dialog-body">
            <p className="dj-dialog-note">
              All {group.files.length} copies move into this folder. The folder is created if
              it does not exist. Check the path before confirming.
            </p>
            <TextInput
              label="Target folder"
              value={mergeTarget}
              onChange={(value) => setMergeTarget(value)}
              placeholder="C:\Users\dhanu\Downloads\Merged"
            />
            <div className="dj-dialog-actions">
              <Button label="Cancel" variant="ghost" onClick={() => setMergeOpen(false)} />
              <Button
                label="Merge"
                variant="primary"
                isDisabled={mergeTarget.trim() === '' || working}
                onClick={() => void handleMerge()}
              />
            </div>
          </div>
        </Dialog>
      </div>
    </Card>
  );
}

interface DuplicatesBlockProps {
  groups: DuplicateGroup[];
  onResult: (text: string) => void;
}

/** Renders one duplicate group per card and refreshes the list after
 *  a delete or merge, so a group that is fully resolved disappears. */
export function DuplicatesBlock({ groups, onResult }: DuplicatesBlockProps) {
  const [current, setCurrent] = useState<DuplicateGroup[]>(groups);

  if (current.length === 0) {
    return <p className="dj-text dj-text-muted">No duplicate groups left.</p>;
  }

  return (
    <>
      {current.map((group) => (
        <GroupCard
          key={group.id}
          group={group}
          onResult={onResult}
          onGroupsChanged={setCurrent}
        />
      ))}
    </>
  );
}
