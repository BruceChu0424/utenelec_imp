'use client';
import { useLocale } from 'next-intl';
import { useRouter, usePathname } from '@/i18n/navigation';
import { useState, useRef, useEffect } from 'react';
import { Globe, Check, ChevronDown } from 'lucide-react';
import { LOCALES } from '@/lib/content';

const NAMES: Record<string, string> = { zh: '中文', en: 'English' };

export function LanguageSwitcher() {
  const locale = useLocale();
  const router = useRouter();
  const pathname = usePathname();
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const h = (e: MouseEvent) => { if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false); };
    document.addEventListener('mousedown', h);
    return () => document.removeEventListener('mousedown', h);
  }, []);
  const change = (l: string) => {
    setOpen(false);
    if (l !== locale) router.replace(pathname, { locale: l });
  };
  return (
    <div ref={ref} className="relative">
      <button onClick={() => setOpen(o => !o)}
        className="inline-flex h-9 items-center gap-1 rounded-lg px-2 text-sm text-foreground/70 transition hover:bg-muted hover:text-foreground cursor-pointer"
        aria-label="Language">
        <Globe className="h-4 w-4" />
        <span className="hidden uppercase sm:inline">{locale}</span>
        <ChevronDown className="h-3 w-3" />
      </button>
      {open && (
        <div className="absolute right-0 z-50 mt-2 w-36 rounded-lg border border-border bg-card py-1 shadow-lg animate-scale-in">
          {LOCALES.map(l => (
            <button key={l} onClick={() => change(l)}
              className="flex w-full items-center justify-between px-3 py-2 text-sm transition hover:bg-muted cursor-pointer">
              {NAMES[l] || l}
              {l === locale && <Check className="h-3 w-3 text-accent" />}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
