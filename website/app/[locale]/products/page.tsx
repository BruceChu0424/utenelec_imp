import { PublicPageIntro } from '@/components/layout/PublicPageIntro';
import type { Metadata } from 'next';
import { getTranslations, setRequestLocale } from 'next-intl/server';
import { SeriesCard } from '@/components/products/SeriesCard';
import { Link } from '@/i18n/navigation';
import { toCatalogFamily } from '@/lib/catalog';
import { getCatalogFamilies } from '@/lib/queries';
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
  const [t, common] = await Promise.all([getTranslations({ locale, namespace: 'Products' }), getTranslations({ locale, namespace: 'Common' })]);
  const familyRecords = await getCatalogFamilies();
  const families = familyRecords.map((family) => toCatalogFamily(family, locale)).filter((family) => family.count > 0);

  return (
    <>
      <PublicPageIntro locale={locale} title={t('title')} description={t('subtitle')} />

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
            <div className="public-family-grid">
              {families.map((family, index) => (
                <SeriesCard
                  key={family.id}
                  family={family}
                  locale={locale}
                  priority={index < 2}
                  featured={index === 0}
                  labels={{ products: t.raw('seriesProducts') as string, explore: t('exploreSeries') }}
                />
              ))}
            </div>
          ) : (
            <div className="rounded-3xl border border-dashed border-border bg-card px-6 py-24 text-center text-muted-foreground"><p>{t('noSeries')}</p><Link locale={locale} href="/contact" className="btn-outline mt-6">{common('contactUs')}</Link></div>
          )}
        </div>
      </section>
    </>
  );
}
