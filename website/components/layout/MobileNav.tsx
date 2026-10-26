'use client';

import Image from 'next/image';
import { useEffect, useId, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { ArrowUpRight, Menu, X } from 'lucide-react';
import { useTranslations } from 'next-intl';
import { LanguageSwitcher } from '@/components/LanguageSwitcher';
import { Link } from '@/i18n/navigation';

export function MobileNav({ locale, series }: { locale: string; series: { code: string; name: string }[] }) {
  const [open, setOpen] = useState(false);
  const dialogId = useId();
  const dialogTitleId = useId();
  const triggerRef = useRef<HTMLButtonElement>(null);
  const dialogRef = useRef<HTMLDivElement>(null);
  const closeButtonRef = useRef<HTMLButtonElement>(null);
  const t = useTranslations('Nav');
  const tc = useTranslations('Common');
  const nav = [
    { href: '/', label: t('home') },
    { href: '/products', label: t('products') },
    { href: '/studio', label: t('studio') },
    { href: '/capabilities', label: t('capabilities') },
    { href: '/partners', label: t('partners') },
    { href: '/resources', label: t('resources') },
    { href: '/about', label: t('about') },
    { href: '/cases', label: t('cases') },
    { href: '/news', label: t('news') },
    { href: '/careers', label: t('careers') },
    { href: '/contact', label: t('contact') },
  ];

  useEffect(() => {
    if (!open) return;

    const trigger = triggerRef.current;
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    const focusFrame = window.requestAnimationFrame(() => closeButtonRef.current?.focus());

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault();
        setOpen(false);
        return;
      }
      if (event.key !== 'Tab') return;

      const focusable = Array.from(
        dialogRef.current?.querySelectorAll<HTMLElement>(
          'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
        ) ?? [],
      ).filter((element) => element.getClientRects().length > 0);

      if (!focusable.length) {
        event.preventDefault();
        dialogRef.current?.focus();
        return;
      }

      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      const activeElement = document.activeElement;
      if (event.shiftKey && (activeElement === first || !dialogRef.current?.contains(activeElement))) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && (activeElement === last || !dialogRef.current?.contains(activeElement))) {
        event.preventDefault();
        first.focus();
      }
    };

    document.addEventListener('keydown', onKeyDown);
    return () => {
      window.cancelAnimationFrame(focusFrame);
      document.body.style.overflow = previousOverflow;
      document.removeEventListener('keydown', onKeyDown);
      window.requestAnimationFrame(() => trigger?.focus());
    };
  }, [open]);

  return (
    <div className="xl:hidden">
      <button
        ref={triggerRef}
        type="button"
        onClick={() => setOpen(true)}
        aria-label={tc('menu')}
        aria-expanded={open}
        aria-controls={dialogId}
        aria-haspopup="dialog"
        className="grid h-11 w-11 place-items-center rounded-full text-foreground transition hover:bg-muted"
      >
        <Menu className="h-5 w-5" />
      </button>

      {open && createPortal(
        <div
          ref={dialogRef}
          id={dialogId}
          className="fixed inset-0 z-[100] overflow-y-auto bg-background"
          role="dialog"
          aria-modal="true"
          aria-labelledby={dialogTitleId}
          tabIndex={-1}
        >
          <h2 id={dialogTitleId} className="sr-only">{tc('menu')}</h2>
          <div className="container-uten sticky top-0 z-10 flex h-[72px] items-center justify-between border-b border-border/70 bg-background/95 backdrop-blur-xl">
            <Image src="/images/logo/logo_name.png" alt="UTEN ELEC" width={150} height={40} className="h-7 w-auto" />
            <button ref={closeButtonRef} type="button" onClick={() => setOpen(false)} aria-label={tc('close')} className="grid h-11 w-11 place-items-center rounded-full transition hover:bg-muted">
              <X className="h-5 w-5" />
            </button>
          </div>

          <div className="container-uten grid gap-10 py-7 md:grid-cols-2">
            <nav className="flex flex-col">
              {nav.map((item, index) => (
                <Link
                  key={item.href}
                  locale={locale}
                  href={item.href}
                  onClick={() => setOpen(false)}
                  className="group flex min-h-14 items-center justify-between border-b border-border/70 text-xl font-semibold"
                >
                  <span><span className="me-3 text-xs tabular-nums text-muted-foreground">{String(index + 1).padStart(2, '0')}</span>{item.label}</span>
                  <ArrowUpRight className="h-4 w-4 text-muted-foreground transition group-hover:-translate-y-0.5 group-hover:translate-x-0.5 group-hover:text-accent" />
                </Link>
              ))}
            </nav>

            <div>
              <p className="eyebrow">{t('products')}</p>
              <div className="mt-5 grid grid-cols-2 gap-2">
                {series.slice(0, 8).map((entry) => (
                  <Link
                    key={entry.code}
                    locale={locale}
                    href={`/products/${entry.code}`}
                    onClick={() => setOpen(false)}
                    className="flex min-h-11 items-center rounded-xl border border-border bg-card px-3 text-sm font-semibold hover:border-accent"
                  >
                    {entry.name}
                  </Link>
                ))}
              </div>
              <Link locale={locale} href="/partners#project-brief" onClick={() => setOpen(false)} className="btn-accent mt-6 w-full">
                {tc('startProject')} <ArrowUpRight className="h-4 w-4" />
              </Link>
              <div className="mt-5 flex justify-center"><LanguageSwitcher /></div>
            </div>
          </div>
        </div>,
        document.body,
      )}
    </div>
  );
}
