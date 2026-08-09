'use client';

import { ArrowUpRight } from 'lucide-react';
import { useLocale, useTranslations } from 'next-intl';
import { Link } from '@/i18n/navigation';

export default function LocaleNotFound() {
  // not-found files do not receive route params. The locale and messages are
  // supplied explicitly by [locale]/layout's NextIntlClientProvider.
  const locale = useLocale();
  const t = useTranslations('NotFound');
  const tc = useTranslations('Common');
  const tn = useTranslations('Nav');

  return (
    <section className="page-hero flex min-h-[68vh] items-center">
      <div className="ambient-blob end-[8%] top-[8%] h-64 w-64 bg-accent/25" />
      <div className="container-uten relative py-10">
        <p className="eyebrow">404 · UTEN</p>
        <h1 className="page-title mt-6 max-w-4xl text-balance">{t('title')}</h1>
        <p className="prose-intro mt-6">{t('desc')}</p>
        <div className="mt-9 flex flex-wrap gap-3">
          <Link locale={locale} href="/" className="btn-primary">{t('cta')} <ArrowUpRight className="h-4 w-4" /></Link>
          <Link locale={locale} href="/products" className="btn-outline">{tn('products')}</Link>
          <Link locale={locale} href="/contact" className="btn-ghost">{tc('contactUs')}</Link>
        </div>
      </div>
    </section>
  );
}
