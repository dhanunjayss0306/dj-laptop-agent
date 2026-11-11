// DJ v3 — folder setup dialog. Shown on first run (no index yet) and
// whenever the user opens it from the "Folders" button in the header.
// Saving stores the config and starts an index build.

import { useEffect, useState } from 'react';
import { Button } from '@astryxdesign/core/Button';
import { CheckboxInput } from '@astryxdesign/core/CheckboxInput';
import { Dialog, DialogHeader } from '@astryxdesign/core/Dialog';

import type { AppConfig } from '../../shared/types';

interface FoldersDialogProps {
  isOpen: boolean;
  /** True on first run: the dialog explains setup instead of editing. */
  isFirstRun: boolean;
  config: AppConfig | null;
  onOpenChange: (open: boolean) => void;
  onSave: (config: AppConfig) => void;
}

export function FoldersDialog({
  isOpen,
  isFirstRun,
  config,
  onOpenChange,
  onSave,
}: FoldersDialogProps) {
  const [draft, setDraft] = useState<AppConfig | null>(config);

  // Reset the draft whenever the dialog opens with fresh config.
  useEffect(() => {
    if (isOpen) {
      setDraft(config);
    }
  }, [isOpen, config]);

  const toggle = (path: string, checked: boolean) => {
    setDraft((prev) => {
      if (!prev) return prev;
      return {
        folders: prev.folders.map((f) =>
          f.path === path ? { ...f, enabled: checked } : f,
        ),
      };
    });
  };

  const enabledCount = draft?.folders.filter((f) => f.enabled).length ?? 0;

  return (
    <Dialog
      isOpen={isOpen}
      onOpenChange={onOpenChange}
      purpose={isFirstRun ? 'required' : 'form'}
      width={520}
    >
      <DialogHeader
        title={isFirstRun ? 'Set up DJ' : 'Folders'}
        onOpenChange={onOpenChange}
      />
      <div className="dj-dialog-body">
        <p className="dj-dialog-note">
          {isFirstRun
            ? 'Choose the folders DJ should search. DJ only reads these folders, on this laptop. Nothing leaves the laptop.'
            : 'Choose the folders DJ should search. Saving rebuilds the index.'}
        </p>
        {draft == null || draft.folders.length === 0 ? (
          <p className="dj-text">No folders configured.</p>
        ) : (
          draft.folders.map((folder) => (
            <div className="dj-folder-row" key={folder.path}>
              <CheckboxInput
                label={folder.path}
                value={folder.enabled}
                onChange={(checked) => toggle(folder.path, checked)}
              />
            </div>
          ))
        )}
        <div className="dj-dialog-actions">
          {!isFirstRun && (
            <Button label="Cancel" variant="ghost" onClick={() => onOpenChange(false)} />
          )}
          <Button
            label={isFirstRun ? 'Save and build index' : 'Save'}
            variant="primary"
            isDisabled={!draft || enabledCount === 0}
            onClick={() => {
              if (draft) onSave(draft);
            }}
          />
        </div>
      </div>
    </Dialog>
  );
}
