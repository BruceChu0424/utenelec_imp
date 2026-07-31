import { setRequestLocale, getTranslations } from 'next-intl/server';
import { notFound } from 'next/navigation';
import type { Metadata } from 'next';
import { Link } from '@/i18n/navigation';
import { ArrowLeft } from 'lucide-react';
import { getSeries, getSeriesByCode } from '@/lib/queries';
import { tr } from '@/lib/content';
import { ProductCard } from '@/components/ProductCard';

export async function generateStaticParams() {
  const series = await getSeries();
  return series.map((s) => ({ code: s.code }));
}

export async function generateMetadata({ params }: { params: { locale: string; code: string } }): Promise<Metadata> {
  const s = await getSeriesByCode(params.code);
  if (!s) return {};
  const name = tr<{ name: string }>(s.i18n, params.locale).name;
  return { title: name };
}

export default async function SeriesPage({ params }: { params: { locale: string; code: string } }) {
  const { locale, code } = params;
  setRequestLocale(locale);
  const t = await getTranslations('Products');
  const tc = await getTranslations('Common');
  const series = await getSeriesByCode(code);
  if (!series) notFound();
  const sd = tr<{ name: string; subtitle?: string; description?: string }>(series.i18n, locale);
  const allSeries = await getSeries();

  return (
    <>
      <section className="relative overflow-hidden border-b border-border/40 bg-background-elevated/50 py-12 md:py-14">
        <div className="ambient-blob" style={{ width: 340, height: 340, background: 'hsl(174 100% 40%)', top: '-40%', right: '8%' }} />
        <div className="container-uten relative">
          <Link href="/products" className="mb-4 inline-flex items-center gap-1 text-sm text-muted-foreground transition hover:text-accent">
            <ArrowLeft className="h-4 w-4" />{tc('back')}
          </Link>
          <span className="block eyebrow">{code.toUpperCase()}</span>
          <h1 className="mt-3 font-heading text-4xl font-bold md:text-5xl"><span className="text-gradient">{sd.name}</span></h1>
          {sd.description && <p className="mt-4 max-w-2xl leading-relaxed text-muted-foreground">{sd.description}</p>}
        </div>
      </section>

      <div className="container-uten py-10">
        <div className="mb-8 flex flex-wrap gap-2">
          <Link href="/products" className="rounded-full border border-border bg-card px-4 py-2 text-sm transition hover:border-accent hover:text-accent">{t('allSeries')}</Link>
          {allSeries.map((s) => {
            const name = tr<{ name: string }>(s.i18n, locale).name;
            return (
              <Link key={s.code} href={`/products/${s.code}`}
                className={`rounded-full px-4 py-2 text-sm transition ${s.code === code ? 'bg-primary text-primary-foreground' : 'border border-border bg-card hover:border-accent hover:text-accent'}`}>
                {name}
              </Link>
            );
          })}
        </div>

        <h2 className="mb-5 text-sm font-semibold uppercase tracking-wider text-muted-foreground">
          {t('count', { count: series.products.length })}
        </h2>
        {series.products.length === 0 ? (
          <p className="py-20 text-center text-muted-foreground">{t('empty')}</p>
        ) : (
          <div className="grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-4">
            {series.products.map((p) => <ProductCard key={p.id} product={{ ...p, series }} locale={locale} />)}
          </div>
        )}
      </div>
    </>
  );
}
