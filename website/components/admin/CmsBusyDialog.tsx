'use client';

import { useEffect, useRef } from 'react';
import { Loader2 } from 'lucide-react';

function BusyPanel({ label }: { label: string }) {
  return <div className="flex items-center gap-3 px-7 py-5"><Loader2 className="h-5 w-5 animate-spin text-accent" aria-hidden="true" /><span role="status" aria-live="polite">{label}</span></div>;
}
export function CmsBusyOverlay({ label }: { label: string }) {
  return <div role="status" aria-live="polite" className="fixed inset-0 z-50 grid place-items-center bg-black/20"><div className="card-uten"><BusyPanel label={label} /></div></div>;
}
/** Only the actual in-flight command mounts a modal; cancel never replays or aborts the write. */
export function CmsBusyDialog({ label, onClosed }: { label: string; onClosed: () => void }) {
  const dialog = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const element = dialog.current;
    if (!element) return;
    element.showModal();
    return () => { element.close(); onClosed(); };
  }, [onClosed]);
  return <dialog ref={dialog} tabIndex={-1} aria-label={label} aria-busy="true" onCancel={event => event.preventDefault()}
    className="m-auto rounded-lg border border-border bg-card p-0 text-foreground shadow-xl backdrop:bg-black/20"><BusyPanel label={label} /></dialog>;
}
