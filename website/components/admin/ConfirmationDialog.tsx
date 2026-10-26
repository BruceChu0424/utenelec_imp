'use client';

import { useEffect, useId, useRef } from 'react';

export function ConfirmationDialog({ open, title, description, confirmLabel, onCancel, onConfirm }: {
  open: boolean; title: string; description: string; confirmLabel: string;
  onCancel: () => void; onConfirm: () => void;
}) {
  const dialog = useRef<HTMLDialogElement>(null);
  const cancel = useRef<HTMLButtonElement>(null);
  const titleId = useId();
  const descriptionId = useId();
  useEffect(() => {
    const element = dialog.current;
    if (!element) return;
    if (open && !element.open) {
      element.showModal();
      cancel.current?.focus();
    } else if (!open && element.open) element.close();
  }, [open]);
  return <dialog ref={dialog} role="alertdialog" aria-labelledby={titleId} aria-describedby={descriptionId}
    onCancel={event => { event.preventDefault(); onCancel(); }}
    className="m-auto w-[calc(100%-2rem)] max-w-lg rounded-2xl border border-border bg-card p-0 text-foreground shadow-xl backdrop:bg-black/45">
    <div className="p-6 sm:p-8">
      <h2 id={titleId} className="text-xl font-semibold">{title}</h2>
      <p id={descriptionId} className="mt-3 text-sm leading-7 text-muted-foreground">{description}</p>
      <div className="mt-7 flex flex-wrap justify-end gap-3">
        <button ref={cancel} type="button" className="btn-outline" onClick={onCancel}>取消</button>
        <button type="button" className="btn-accent" onClick={onConfirm}>{confirmLabel}</button>
      </div>
    </div>
  </dialog>;
}
