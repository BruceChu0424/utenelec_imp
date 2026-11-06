import { Info } from 'lucide-react';

/** Native title on hover, with a keyboard/touch disclosure alongside its heading. */
export function AdminHint({ text }: { text: string }) {
  return <details className="relative inline-block align-middle text-muted-foreground">
    <summary title={text} aria-label={text} className="inline-flex cursor-pointer list-none rounded p-1 focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"><Info className="h-4 w-4" aria-hidden="true" /></summary>
    <div className="absolute left-0 top-full z-30 mt-1 w-72 max-w-[80vw] rounded-lg border border-border bg-card p-3 text-left text-sm font-normal leading-6 text-foreground shadow-lg">{text}</div>
  </details>;
}
