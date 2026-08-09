'use client';

import Image from 'next/image';
import { ArrowUpRight, ChevronDown } from 'lucide-react';
import { useTranslations } from 'next-intl';
import { LanguageSwitcher } from '@/components/LanguageSwitcher';
import { Link, usePathname } from '@/i18n/navigation';
import { MobileNav } from './MobileNav';

export function SiteHeader({ locale, series }: { locale: string; series: { code: string; name: string }[] }) {
  const t = useTranslations('Nav');
  const tc = useTranslations('Common');
  const pathname = usePathname();
  const isActive = (href: string) => pathname === href || pathname.startsWith(`${href}/`);
  const items = [
    { href: '/', label: t('home') },
    { href: '/products', label: t('products'), mega: true },
    { href: '/studio', label: t('studio') },
    { href: '/capabilities', label: t('capabilities') },
    { href: '/partners', label: t('partners') },
    { href: '/resources', label: t('resources') },
    { href: '/about', label: t('about') },
  ];

  return (
    <header className="sticky top-0 z-50 border-b border-border/70 bg-background/90 backdrop-blur-xl">
      <div className="container-uten flex h-[72px] items-center justify-between gap-5">
        <Link locale={locale} href="/" className="group flex min-h-11 shrink-0 items-center" aria-label={t('home')}>
          <Image
            src="/images/logo/logo_name.png"
            alt="UTEN ELEC"
            width={160}
            height={42}
            priority
            className="h-7 w-auto transition duration-300 group-hover:opacity-75"
          />
        </Link>

        <nav className="hidden items-center xl:flex" aria-label={t('primaryNavigation')}>
          {items.map((item) => (
            <div key={item.href} className="group relative px-0.5 focus-within:z-50">
              <Link
                locale={locale}
                href={item.href}
                className={`relative inline-flex min-h-11 items-center gap-1 whitespace-nowrap px-2 text-[13px] font-semibold transition 2xl:gap-1.5 2xl:px-3.5 2xl:text-sm ${
                  isActive(item.href) ? 'text-foreground' : 'text-foreground/62 hover:text-foreground'
                }`}
              >
                {item.label}
                {item.mega && <ChevronDown className="h-3.5 w-3.5 transition duration-300 group-hover:rotate-180" />}
                <span className={`absolute inset-x-2 bottom-1 h-px origin-left bg-accent transition-transform duration-300 2xl:inset-x-3.5 ${
                  isActive(item.href) ? 'scale-x-100' : 'scale-x-0 group-hover:scale-x-100'
                }`} />
              </Link>

              {item.mega && (
                <div className="invisible absolute left-1/2 top-full w-[min(760px,88vw)] -translate-x-1/2 translate-y-2 pt-3 opacity-0 transition duration-200 group-hover:visible group-hover:translate-y-0 group-hover:opacity-100 group-focus-within:visible group-focus-within:translate-y-0 group-focus-within:opacity-100">
                  <div className="overflow-hidden rounded-[1.4rem] border border-border bg-card shadow-lg">
                    <div className="grid grid-cols-[210px_1fr]">
                      <div className="panel-dark p-6">
                        <p className="text-[11px] font-bold uppercase tracking-[.22em] text-accent-soft">{t('collections')}</p>
                        <p className="mt-4 text-balance text-2xl font-semibold leading-tight">{t('products')}</p>
                        <p className="mt-3 text-sm leading-relaxed text-primary-foreground/62">{tc('catalogHint')}</p>
                        <Link locale={locale} href="/products" className="mt-6 inline-flex items-center gap-1.5 text-sm font-semibold text-primary-foreground">
                          {tc('viewAll')} <ArrowUpRight className="h-4 w-4" />
                        </Link>
                      </div>
                      <div className="grid grid-cols-3 gap-x-3 gap-y-1 p-5">
                        {series.slice(0, 12).map((entry) => (
                          <Link
                            key={entry.code}
                            locale={locale}
                            href={`/products/${entry.code}`}
                            className="flex min-h-11 items-center rounded-xl px-3 text-sm font-medium text-foreground/72 transition hover:bg-muted hover:text-foreground"
                          >
                            {entry.name}
                          </Link>
                        ))}
                      </div>
                    </div>
                  </div>
                </div>
              )}
            </div>
          ))}
        </nav>

        <div className="flex items-center gap-1.5">
          <div className="hidden md:block"><LanguageSwitcher /></div>
          <Link locale={locale} href="/contact" className="btn-primary btn-sm ms-1 hidden md:inline-flex">
            {tc('getAdvice')} <ArrowUpRight className="h-4 w-4" />
          </Link>
          <MobileNav locale={locale} series={series} />
        </div>
      </div>
    </header>
  );
}
