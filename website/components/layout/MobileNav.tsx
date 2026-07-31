'use client';
import { useState } from 'react';
import { Link, usePathname } from '@/i18n/navigation';
import { Menu, X, ChevronRight } from 'lucide-react';
import { useTranslations } from 'next-intl';
import { LanguageSwitcher } from '@/components/LanguageSwitcher';
import { ThemeToggle } from '@/components/ThemeToggle';

export function MobileNav({ series }: { series: { code: string; name: string }[] }) {
  const [open, setOpen] = useState(false);
  const t = useTranslations('Nav');
  const pathname = usePathname();
  const nav = [
    { href: '/about', label: t('about') },
    { href: '/products', label: t('products') },
    { href: '/news', label: t('news') },
    { href: '/cases', label: t('cases') },
    { href: '/join', label: t('join') },
    { href: '/careers', label: t('careers') },
    { href: '/contact', label: t('contact') },
  ];
  return (
    <div className="md:hidden">
      <button onClick={() => setOpen(true)} aria-label={t('home')}
        className="inline-flex h-9 w-9 items-center justify-center rounded-lg text-foreground/80 hover:bg-muted cursor-pointer">
        <Menu className="h-5 w-5" />
      </button>
      {open && (
        <div className="fixed inset-0 z-[100] bg-background">
          <div className="flex h-16 items-center justify-between border-b border-border px-4">
            <span className="font-heading text-lg font-bold">优腾 UTEN</span>
            <button onClick={() => setOpen(false)} aria-label="close"
              className="inline-flex h-9 w-9 items-center justify-center rounded-lg hover:bg-muted cursor-pointer">
              <X className="h-5 w-5" />
            </button>
          </div>
          <nav className="flex flex-col px-4 py-2">
            {nav.map(item => (
              <Link key={item.href} href={item.href} onClick={() => setOpen(false)}
                className="flex items-center justify-between border-b border-border/60 py-4 text-base font-medium hover:text-accent">
                {item.label}
                <ChevronRight className="h-4 w-4 text-muted-foreground" />
              </Link>
            ))}
          </nav>
          <div className="px-4 py-4">
            <p className="mb-2 text-xs uppercase tracking-wider text-muted-foreground">{t('products')}</p>
            <div className="grid grid-cols-3 gap-2">
              {series.slice(0, 9).map(s => (
                <Link key={s.code} href={`/products/${s.code}`} onClick={() => setOpen(false)}
                  className="rounded-lg bg-muted px-3 py-2 text-center text-xs hover:bg-accent hover:text-accent-foreground">
                  {s.name}
                </Link>
              ))}
            </div>
          </div>
          <div className="absolute bottom-6 left-0 right-0 flex items-center justify-center gap-4">
            <LanguageSwitcher />
            <ThemeToggle />
          </div>
        </div>
      )}
    </div>
  );
}
