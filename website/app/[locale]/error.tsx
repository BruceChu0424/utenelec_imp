'use client';

import { ArrowUpRight } from 'lucide-react';
import { useLocale, useTranslations } from 'next-intl';
import { Link } from '@/i18n/navigation';

export default function LocaleError() {
  const locale = useLocale();
  const tc = useTranslations('Common');
  const tn = useTranslations('Nav');
  const tf = useTranslations('Footer');

  return (
    <section className="page-hero flex min-h-[68vh] items-center">
      <div className="ambient-blob end-[8%] top-[8%] h-64 w-64 bg-accent/25" />
      <div className="container-uten relative py-10">
        <p className="eyebrow">UTEN · SYSTEM</p>
        <h1 className="page-title mt-6 max-w-4xl text-balance">{tc('error')}</h1>
        <p className="prose-intro mt-6">{tf('brandStatement')}</p>
        <div className="mt-9 flex flex-wrap gap-3">
          <Link locale={locale} href="/" className="btn-primary">{tc('backHome')} <ArrowUpRight className="h-4 w-4" /></Link>
          <Link locale={locale} href="/products" className="btn-outline">{tn('products')}</Link>
          <Link locale={locale} href="/contact" className="btn-ghost">{tn('contact')}</Link>
        </div>
      </div>
    </section>
  );
}
