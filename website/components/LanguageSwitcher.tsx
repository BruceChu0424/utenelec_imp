'use client';

import { Check, ChevronDown, Globe2 } from 'lucide-react';
import { useLocale, useTranslations } from 'next-intl';
import { useEffect, useRef, useState, type KeyboardEvent as ReactKeyboardEvent } from 'react';
import { usePathname, useRouter } from '@/i18n/navigation';
import { LOCALES } from '@/lib/content';

const NAMES: Record<string, string> = {
  zh: '中文', en: 'English', es: 'Español', fr: 'Français', de: 'Deutsch',
  pt: 'Português', ar: 'العربية', ru: 'Русский', ja: '日本語', ko: '한국어',
};

export function LanguageSwitcher() {
  const locale = useLocale();
  const t = useTranslations('Locale');
  const router = useRouter();
  const pathname = usePathname();
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const outside = (event: MouseEvent) => {
      if (ref.current && !ref.current.contains(event.target as Node)) setOpen(false);
    };
    const escape = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && open) {
        setOpen(false);
        window.requestAnimationFrame(() => triggerRef.current?.focus());
      }
    };
    document.addEventListener('mousedown', outside);
    document.addEventListener('keydown', escape);
    return () => {
      document.removeEventListener('mousedown', outside);
      document.removeEventListener('keydown', escape);
    };
  }, [open]);

  useEffect(() => {
    if (!open) return;
    window.requestAnimationFrame(() => {
      menuRef.current?.querySelector<HTMLElement>('[aria-checked="true"]')?.focus();
    });
  }, [open]);

  const change = (nextLocale: string) => {
    setOpen(false);
    if (nextLocale === locale) return;
    const query = typeof window === 'undefined' ? '' : window.location.search;
    router.replace(`${pathname}${query}`, { locale: nextLocale });
  };

  const moveFocus = (event: ReactKeyboardEvent, target: 'next' | 'previous' | 'first' | 'last') => {
    const items = Array.from(menuRef.current?.querySelectorAll<HTMLButtonElement>('[role="menuitemradio"]') || []);
    if (!items.length) return;
    event.preventDefault();
    const current = Math.max(0, items.indexOf(document.activeElement as HTMLButtonElement));
    const index = target === 'first' ? 0 : target === 'last' ? items.length - 1 : target === 'next' ? (current + 1) % items.length : (current - 1 + items.length) % items.length;
    items[index]?.focus();
  };

  return (
    <div ref={ref} className="relative">
      <button
        ref={triggerRef}
        type="button"
        onClick={() => setOpen((value) => !value)}
        onKeyDown={(event) => {
          if (!open && (event.key === 'ArrowDown' || event.key === 'Enter' || event.key === ' ')) {
            event.preventDefault();
            setOpen(true);
          }
        }}
        className="inline-flex min-h-11 items-center gap-2 rounded-full px-3 text-sm font-semibold text-foreground/68 transition hover:bg-muted hover:text-foreground"
        aria-label={t('switch')}
        aria-expanded={open}
        aria-haspopup="menu"
      >
        <Globe2 className="h-4 w-4" />
        <span>{locale.toUpperCase()}</span>
        <ChevronDown className={`h-3.5 w-3.5 transition ${open ? 'rotate-180' : ''}`} />
      </button>

      {open && (
        <div ref={menuRef} className="absolute end-0 z-[110] mt-2 grid max-h-[min(70vh,420px)] w-48 overflow-y-auto rounded-2xl border border-border bg-card p-1.5 shadow-lg" role="menu" onKeyDown={(event) => {
          if (event.key === 'ArrowDown') moveFocus(event, 'next');
          else if (event.key === 'ArrowUp') moveFocus(event, 'previous');
          else if (event.key === 'Home') moveFocus(event, 'first');
          else if (event.key === 'End') moveFocus(event, 'last');
        }}>
          {LOCALES.map((entry) => (
            <button
              type="button"
              key={entry}
              onClick={() => change(entry)}
              role="menuitemradio"
              aria-checked={entry === locale}
              className="flex min-h-11 w-full items-center justify-between rounded-xl px-3 text-sm font-medium transition hover:bg-muted"
            >
              {NAMES[entry] || entry}
              {entry === locale && <Check className="h-4 w-4 text-accent" />}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
