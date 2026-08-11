import type { Metadata } from 'next';
import { ArrowDown, Box, Boxes, Layers3 } from 'lucide-react';
import { getTranslations, setRequestLocale } from 'next-intl/server';
import { SeriesCard } from '@/components/products/SeriesCard';
import { Link } from '@/i18n/navigation';
import { toCatalogFamily } from '@/lib/catalog';
import { getCatalogFamilies, getProductCount } from '@/lib/queries';
import { buildPageMetadata } from '@/lib/seo';

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: 'Products' });
  const catalogLocales = ['zh', 'en'];
  return buildPageMetadata({
    locale,
    path: '/products',
    title: t('title'),
    description: t('subtitle'),
    availableLocales: catalogLocales,
    index: catalogLocales.includes(locale),
  });
}

export default async function ProductsPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  setRequestLocale(locale);
  const t = await getTranslations('Products');
  const [familyRecords, total] = await Promise.all([getCatalogFamilies(), getProductCount()]);
  const families = familyRecords.map((family) => toCatalogFamily(family, locale)).filter((family) => family.count > 0);

  return (
    <>
      <section className="page-hero">
        <div className="container-uten relative">
          <div className="grid items-end gap-10 lg:grid-cols-[minmax(0,1fr)_minmax(300px,.46fr)] lg:gap-16">
            <div>
              <p className="eyebrow">UTEN PRODUCT SYSTEM</p>
              <h1 className="section-title mt-7 max-w-4xl">{t('title')}</h1>
              <p className="mt-6 max-w-2xl text-pretty text-base leading-8 text-muted-foreground md:text-lg">{t('subtitle')}</p>
              <div className="mt-8 flex flex-col gap-3 sm:flex-row">
                <a href="#series-index" className="btn-accent"><ArrowDown className="h-4 w-4" />{t('browseSeries')}</a>
                <Link href="/studio" className="btn-outline"><Box className="h-4 w-4" />{t('tryOnWall')}</Link>
              </div>
            </div>
            <dl className="grid grid-cols-2 overflow-hidden rounded-2xl border border-border bg-card">
              <div className="border-e border-border p-5 sm:p-6">
                <dt className="flex items-center gap-2 text-[10px] font-bold uppercase tracking-[.14em] text-muted-foreground"><Boxes className="h-4 w-4 text-accent" />{t('modelsLabel')}</dt>
                <dd className="mt-3 text-3xl font-semibold tracking-[-.04em]">{total}</dd>
              </div>
              <div className="p-5 sm:p-6">
                <dt className="flex items-center gap-2 text-[10px] font-bold uppercase tracking-[.14em] text-muted-foreground"><Layers3 className="h-4 w-4 text-accent" />{t('finishesLabel')}</dt>
                <dd className="mt-3 text-3xl font-semibold tracking-[-.04em]">{families.length}</dd>
              </div>
            </dl>
          </div>
        </div>
      </section>

      <section id="series-index" className="section-tight scroll-mt-24">
        <div className="container-uten">
          <div className="mb-10 grid gap-5 lg:grid-cols-[.8fr_1.2fr] lg:items-end">
            <div>
              <p className="eyebrow">{t('seriesIntro')}</p>
              <h2 className="mt-5 text-3xl font-semibold tracking-[-.04em] md:text-5xl">{t('browseSeriesTitle')}</h2>
            </div>
            <p className="max-w-2xl text-base leading-8 text-muted-foreground lg:justify-self-end">{t('browseSeriesBody')}</p>
          </div>

          {families.length ? (
            <div className="grid gap-5 md:grid-cols-2 xl:gap-7">
              {families.map((family, index) => (
                <SeriesCard
                  key={family.id}
                  family={family}
                  priority={index < 2}
                  labels={{ products: t('seriesProducts'), explore: t('exploreSeries') }}
                />
              ))}
            </div>
          ) : (
            <div className="rounded-3xl border border-dashed border-border bg-card px-6 py-24 text-center text-muted-foreground">{t('noSeries')}</div>
          )}
        </div>
      </section>
    </>
  );
}
