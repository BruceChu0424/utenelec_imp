import type { Metadata } from 'next';
import { ArrowLeft, Box, Layers3 } from 'lucide-react';
import { getTranslations, setRequestLocale } from 'next-intl/server';
import { notFound, permanentRedirect } from 'next/navigation';
import { ProductExplorer } from '@/components/products/ProductExplorer';
import { SeriesCollage } from '@/components/products/SeriesCollage';
import { StructuredData } from '@/components/products/StructuredData';
import { Link } from '@/i18n/navigation';
import { toCatalogFamily } from '@/lib/catalog';
import { catalogSeriesRedirectTarget } from '@/lib/catalog-routing';
import { pickLocale } from '@/lib/content';
import { isProductFunctionType } from '@/lib/product-taxonomy';
import { getCatalogFamilies, queryCatalogProducts, resolveCatalogFamily } from '@/lib/queries';
import { buildPageMetadata, directContentLocales, hasText, localizedUrl } from '@/lib/seo';

type PageSearchParams = Record<string, string | string[] | undefined>;

function firstValue(value: string | string[] | undefined): string {
  return Array.isArray(value) ? value[0] || '' : value || '';
}

function parseGang(value: string): number | null {
  const parsed = Number.parseInt(value, 10);
  return Number.isInteger(parsed) && parsed >= 1 && parsed <= 12 ? parsed : null;
}

function safeFilterQuery(searchParams: PageSearchParams): string {
  const output = new URLSearchParams();
  const query = firstValue(searchParams.q).trim().slice(0, 80);
  const functionType = firstValue(searchParams.function);
  const gang = parseGang(firstValue(searchParams.gang));
  if (query) output.set('q', query);
  if (isProductFunctionType(functionType)) output.set('function', functionType);
  if (gang) output.set('gang', String(gang));
  const value = output.toString();
  return value ? `?${value}` : '';
}

export async function generateStaticParams() {
  const families = await getCatalogFamilies();
  // Only pre-render canonical public URLs. Pre-rendering a legacy alias turns
  // Next.js' permanentRedirect into a 200 HTML page with a meta refresh. By
  // leaving aliases dynamic, requests receive a real HTTP 308 response while
  // canonical series pages keep the static fast path.
  return families.map((family) => ({ code: family.publicSlug || family.code }));
}

export async function generateMetadata({ params }: { params: Promise<{ locale: string; code: string }> }): Promise<Metadata> {
  const { locale, code } = await params;
  const resolution = await resolveCatalogFamily(code);
  if (!resolution) return { robots: { index: false, follow: false } };
  const direct = pickLocale<{ name?: string; description?: string }>(resolution.family.i18n, locale);
  const availableLocales = directContentLocales<{ name?: string }>(resolution.family.i18n, (content) => hasText(content.name));
  const isLocalized = availableLocales.includes(locale);
  const view = toCatalogFamily(resolution.family, locale);
  return buildPageMetadata({
    locale,
    path: `/products/${resolution.canonicalSlug}`,
    title: direct?.name || view.name,
    description: isLocalized ? direct?.description : undefined,
    availableLocales,
    index: isLocalized,
    image: view.images[0]?.src,
  });
}

export default async function SeriesPage({
  params,
  searchParams,
}: {
  params: Promise<{ locale: string; code: string }>;
  searchParams: Promise<PageSearchParams>;
}) {
  const [{ locale, code }, filters] = await Promise.all([params, searchParams]);
  setRequestLocale(locale);
  const resolution = await resolveCatalogFamily(code);
  if (!resolution) notFound();
  const redirectTarget = catalogSeriesRedirectTarget({
    locale,
    requestedFamily: code,
    canonicalFamily: resolution.canonicalSlug,
    query: safeFilterQuery(filters),
  });
  if (redirectTarget) permanentRedirect(redirectTarget);

  const t = await getTranslations({ locale, namespace: 'Products' });
  const tc = await getTranslations({ locale, namespace: 'Common' });
  const result = await queryCatalogProducts({
    locale,
    familyIdentifier: resolution.canonicalSlug,
    take: 5000,
    standardName: t('standardVariant'),
  });
  if (!result) notFound();
  const family = toCatalogFamily(resolution.family, locale);
  const requestedFunction = firstValue(filters.function);
  const initialFunction = isProductFunctionType(requestedFunction) ? requestedFunction : null;
  const initialGang = parseGang(firstValue(filters.gang));
  const functionTypes = {
    switches: t('functionTypes.switches'),
    'power-sockets': t('functionTypes.power-sockets'),
    'usb-charging': t('functionTypes.usb-charging'),
    'data-media': t('functionTypes.data-media'),
    'smart-controls': t('functionTypes.smart-controls'),
    hospitality: t('functionTypes.hospitality'),
    accessories: t('functionTypes.accessories'),
    other: t('functionTypes.other'),
  };
  const pageUrl = localizedUrl(locale, `/products/${family.slug}`);

  return (
    <>
      <StructuredData data={[
        {
          '@context': 'https://schema.org',
          '@type': 'BreadcrumbList',
          itemListElement: [
            { '@type': 'ListItem', position: 1, name: t('title'), item: localizedUrl(locale, '/products') },
            { '@type': 'ListItem', position: 2, name: family.name, item: pageUrl },
          ],
        },
        {
          '@context': 'https://schema.org',
          '@type': 'CollectionPage',
          name: family.name,
          description: family.description,
          url: pageUrl,
          mainEntity: {
            '@type': 'ItemList',
            numberOfItems: result.total,
            itemListElement: result.products.slice(0, 24).map((product, index) => ({
              '@type': 'ListItem',
              position: index + 1,
              name: product.name,
              url: localizedUrl(locale, product.href),
            })),
          },
        },
      ]} />

      <section className="page-hero">
        <div className="container-uten relative">
          <Link locale={locale} href="/products" className="inline-flex min-h-11 items-center gap-2 text-sm font-semibold text-muted-foreground transition hover:text-accent">
            <ArrowLeft className="h-4 w-4 rtl:rotate-180" />{tc('back')}
          </Link>
          <div className="mt-7 grid items-center gap-9 lg:grid-cols-[minmax(0,.82fr)_minmax(420px,1.18fr)] lg:gap-14">
            <div>
              <p className="eyebrow">{t('seriesIntro')}</p>
              <h1 className="section-title mt-6 max-w-3xl">{family.name}</h1>
              {family.subtitle && <p className="mt-5 text-lg font-semibold leading-7 text-foreground/80">{family.subtitle}</p>}
              {family.description && <p className="mt-5 max-w-2xl text-pretty text-base leading-8 text-muted-foreground">{family.description}</p>}
              <div className="mt-7 flex flex-wrap gap-2">
                {family.collections.slice(0, 6).map((collection) => (
                  <span key={collection.id} className="rounded-full border border-border bg-card px-3 py-2 text-xs font-semibold text-muted-foreground">
                    {collection.name}<span className="ms-2 opacity-60">{collection.count}</span>
                  </span>
                ))}
              </div>
              <div className="mt-8 flex flex-wrap gap-3">
                <a href="#product-matrix" className="btn-accent"><Layers3 className="h-4 w-4" />{t('viewProductMatrix')}</a>
                <Link locale={locale} href="/studio" className="btn-outline"><Box className="h-4 w-4" />{t('tryOnWall')}</Link>
              </div>
            </div>
            <SeriesCollage images={family.images} name={family.name} priority className="aspect-[16/11] rounded-[1.5rem] border border-border shadow-sm" />
          </div>
        </div>
      </section>

      <section id="product-matrix" className="section-tight scroll-mt-20">
        <div className="container-uten">
          <div className="mb-9 max-w-3xl">
            <p className="eyebrow">{t('productMatrixEyebrow')}</p>
            <h2 className="mt-5 text-3xl font-semibold tracking-[-.04em] md:text-5xl">{t('productMatrixTitle')}</h2>
            <p className="mt-5 text-base leading-8 text-muted-foreground">{t('productMatrixBody')}</p>
          </div>
          <ProductExplorer
            products={result.products}
            locale={locale}
            initialQuery={firstValue(filters.q).trim().slice(0, 80)}
            initialFunction={initialFunction}
            initialGang={initialGang}
            labels={{
              search: tc('searchPlaceholder'),
              resultCount: t.raw('resultCount') as string,
              variants: t('variants'),
              viewDetail: t('viewDetail'),
              empty: t('empty'),
              clear: t('clear'),
              filter: t('filter'),
              filterFunction: t('filterFunction'),
              filterGang: t('filterGang'),
              allFunctions: t('allFunctions'),
              allGangs: t('allGangs'),
              gang: t.raw('gang') as string,
              closeFilter: tc('close'),
              unspecified: t('unspecified'),
              functionTypes,
            }}
          />
        </div>
      </section>
    </>
  );
}
