'use client';
import Image from 'next/image';
import { useTranslations } from 'next-intl';
import { LanguageSwitcher } from '@/components/LanguageSwitcher';
import { Link, usePathname } from '@/i18n/navigation';
import { MobileNav } from './MobileNav';

export function SiteHeader({ locale, series }: { locale: string; series: { code: string; name: string }[] }) {
  const t = useTranslations('Nav');
  const common = useTranslations('Common');
  const pathname = usePathname();
  const items = [['/products', t('products')], ['/studio', t('studio')], ['/capabilities', t('capabilities')], ['/about', t('about')], ['/news', t('news')]];
  return <header className="public-header"><div className="container-uten">
    <Link locale={locale} href="/" className="public-logo" aria-label={t('home')}><Image src="/images/logo/logo_name.png" alt="UTEN ELEC" width={2240} height={361} priority /></Link>
    <nav className="public-desktop-nav" aria-label={t('primaryNavigation')}>{items.map(([href, label]) => <Link locale={locale} key={href} href={href} aria-current={pathname === href || pathname.startsWith(href + '/') ? 'page' : undefined}>{label}</Link>)}</nav>
    <div className="public-header-actions"><div className="hidden md:block"><LanguageSwitcher /></div><Link locale={locale} href="/contact" className="btn-primary hidden sm:inline-flex">{common('contactUs')}</Link><MobileNav locale={locale} series={series} /></div>
  </div></header>;
}
