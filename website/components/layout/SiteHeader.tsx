'use client';
import { Link, usePathname } from '@/i18n/navigation';
import { useTranslations } from 'next-intl';
import { LanguageSwitcher } from '@/components/LanguageSwitcher';
import { ThemeToggle } from '@/components/ThemeToggle';
import { MobileNav } from './MobileNav';
import { ChevronDown } from 'lucide-react';

export function SiteHeader({ series }: { series: { code: string; name: string }[] }) {
  const t = useTranslations('Nav');
  const tc = useTranslations('Common');
  const pathname = usePathname();
  const isActive = (h: string) => pathname === h || pathname.startsWith(h + '/');
  const items = [
    { href: '/news', label: t('news') },
    { href: '/cases', label: t('cases') },
    { href: '/join', label: t('join') },
    { href: '/careers', label: t('careers') },
    { href: '/contact', label: t('contact') },
  ];
  const link = (active: boolean) =>
    `relative cursor-pointer px-3 py-2 text-sm font-medium transition ${active ? 'text-accent' : 'text-foreground/80 hover:text-foreground'}`;

  return (
    <header className="sticky top-0 z-50 border-b border-border/40 bg-background/70 backdrop-blur-xl">
      <div className="container-uten flex h-16 items-center justify-between gap-4">
        <Link href="/" className="flex shrink-0 items-center">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src="/images/logo/logo_name.png" alt="UTEN ELEC 优腾电器" className="h-6 w-auto sm:h-7" />
        </Link>

        <nav className="hidden items-center gap-1 md:flex">
          <Link href="/about" className={link(isActive('/about'))}>{t('about')}</Link>
          <div className="group relative">
            <Link href="/products" className={link(isActive('/products')) + ' inline-flex items-center gap-1'}>
              {t('products')} <ChevronDown className="h-3 w-3 transition group-hover:rotate-180" />
            </Link>
            <div className="invisible absolute left-1/2 top-full z-50 w-[min(640px,90vw)] -translate-x-1/2 pt-3 opacity-0 transition-all duration-200 group-hover:visible group-hover:opacity-100">
              <div className="rounded-2xl border border-border bg-card p-5 shadow-lg">
                <div className="grid grid-cols-3 gap-1">
                  {series.map(s => (
                    <Link key={s.code} href={`/products/${s.code}`}
                      className="rounded-lg px-3 py-2 text-sm transition hover:bg-muted hover:text-accent">
                      {s.name}
                    </Link>
                  ))}
                </div>
                <Link href="/products"
                  className="mt-3 block rounded-lg bg-muted px-3 py-2 text-center text-sm font-medium text-primary transition hover:bg-primary hover:text-primary-foreground">
                  {tc('viewAll')} →
                </Link>
              </div>
            </div>
          </div>
          {items.map(it => (
            <Link key={it.href} href={it.href} className={link(isActive(it.href))}>{it.label}</Link>
          ))}
        </nav>

        <div className="flex items-center gap-1">
          <div className="hidden md:block"><LanguageSwitcher /></div>
          <div className="hidden md:block"><ThemeToggle /></div>
          <Link href="/contact" className="btn-accent btn-sm ml-2 hidden sm:inline-flex">{tc('contactUs')}</Link>
          <MobileNav series={series} />
        </div>
      </div>
    </header>
  );
}
