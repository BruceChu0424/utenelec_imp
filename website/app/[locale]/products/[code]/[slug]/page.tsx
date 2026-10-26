import { getPublicResources } from '@/lib/resources';
import { PublicResourceList } from '@/components/products/PublicResourceList';
import type { Metadata } from 'next';
import { ArrowLeft, CheckCircle2 } from 'lucide-react';
import { getTranslations, setRequestLocale } from 'next-intl/server';
import { notFound, permanentRedirect } from 'next/navigation';
import { cache } from 'react';
import { ProductMatrixCard } from '@/components/products/ProductMatrixCard';
import { StructuredData } from '@/components/products/StructuredData';
import { VariantViewer } from '@/components/products/VariantViewer';
import { Link } from '@/i18n/navigation';
import {
  catalogFamilyDisplayName,
  catalogFamilySlug,
  catalogSeriesIdentifiers,
  type ProductWithRelations,
} from '@/lib/catalog';
import { publicProductView } from '@/lib/public-product';
import { catalogProductRedirectTarget } from '@/lib/catalog-routing';
import { pickLocale, tr } from '@/lib/content';
import { getProductBySlug, queryCatalogProducts } from '@/lib/queries';
import { buildPageMetadata, directContentLocales, hasText, localizedUrl } from '@/lib/seo';

export const dynamicParams = true;
// Resolve locale-specific server navigation and legacy aliases per request.
// A full-page ISR entry can otherwise retain a pre-normalization alias or
// links rendered from another locale's implicit next-intl request context.
export const dynamic = 'force-dynamic';

const getCachedProduct = cache(getProductBySlug);

function firstValue(value: string | string[] | undefined): string {
  return Array.isArray(value) ? value[0] || '' : value || '';
}

export async function generateMetadata({ params }: { params: Promise<{ locale: string; code: string; slug: string }> }): Promise<Metadata> {
  const { locale, code, slug } = await params;
  const product = await getCachedProduct(slug) as ProductWithRelations | null;
  if (!product || !product.series || !catalogSeriesIdentifiers(product.series).has(code)) {
    notFound();
  }
  const familySlug = catalogFamilySlug(product.series);
  if (!familySlug) notFound();
  const direct = pickLocale<{ name?: string; description?: string }>(product.i18n, locale);
  const fallback = tr<{ name?: string; description?: string }>(product.i18n, locale);
  const availableLocales = directContentLocales<{ name?: string }>(product.i18n, (content) => hasText(content.name));
  const isLocalized = availableLocales.includes(locale);
  const image = product.variants.find((variant) => variant.image)?.image || product.image;
  const seriesName = catalogFamilyDisplayName(product.series, locale);
  const productName = direct?.name || fallback.name || product.model || product.slug;
  return buildPageMetadata({
    locale,
    path: `/products/${familySlug}/${slug}`,
    title: `${productName} · ${seriesName}`,
    // Legacy descriptions can contain old packaging, model and electrical
    // claims. Keep them out of search snippets until an editor has verified
    // this product's structured classification.
    description: isLocalized && product.classificationStatus === 'VERIFIED' ? direct?.description : undefined,
    availableLocales,
    index: isLocalized,
    image,
  });
}

export default async function ProductDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ locale: string; code: string; slug: string }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const [{ locale, code, slug }, query] = await Promise.all([params, searchParams]);
  setRequestLocale(locale);
  const product = await getCachedProduct(slug) as ProductWithRelations | null;
  if (!product || !product.published || !product.series || !product.series.published) notFound();
  const validIdentifiers = catalogSeriesIdentifiers(product.series);
  if (!validIdentifiers.has(code)) notFound();
  const familySlug = catalogFamilySlug(product.series);
  if (!familySlug) notFound();
  const requestedVariant = firstValue(query.variant).trim().slice(0, 120);
  const redirectTarget = catalogProductRedirectTarget({
    locale,
    requestedFamily: code,
    canonicalFamily: familySlug,
    productSlug: slug,
    variant: requestedVariant,
  });
  if (redirectTarget) permanentRedirect(redirectTarget);

  const t = await getTranslations({ locale, namespace: 'Products' });
  const tc = await getTranslations({ locale, namespace: 'Common' });
  const resourcesT = await getTranslations({ locale, namespace: 'Resources' });
  const resources = await getPublicResources(locale, product.id);
  const view = publicProductView(product, locale, t('standardVariant'));
  if (requestedVariant && !view.variants.some(variant => variant.id === requestedVariant)) notFound();
  const seriesName = catalogFamilyDisplayName(product.series, locale);
  const productName = view.name;
  const taxonomy = { functionType: view.functionType, status: product.classificationStatus };
  const reviewedDescription = view.description;
  const variants = view.variants;
  const productGallery = variants.flatMap(variant => variant.gallery);
  const relatedResult = await queryCatalogProducts({
    locale,
    familyIdentifier: familySlug,
    functionType: taxonomy.functionType,
    take: 12,
    standardName: t('standardVariant'),
  });
  const related = (relatedResult?.products || []).filter((item) => item.id !== product.id).slice(0, 3);
  const specs = view.specs;
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
  const canonicalPath = `/products/${familySlug}/${slug}`;
  const canonicalUrl = localizedUrl(locale, canonicalPath);
  const schemaImages = Array.from(new Set([
    ...variants.flatMap((variant) => variant.gallery || [variant.image]),
    ...productGallery,
  ])).filter(Boolean).map((image) => new URL(image, canonicalUrl).toString());

  return (
    <>
      <StructuredData data={[
        {
          '@context': 'https://schema.org',
          '@type': 'BreadcrumbList',
          itemListElement: [
            { '@type': 'ListItem', position: 1, name: t('title'), item: localizedUrl(locale, '/products') },
            { '@type': 'ListItem', position: 2, name: seriesName, item: localizedUrl(locale, `/products/${familySlug}`) },
            { '@type': 'ListItem', position: 3, name: productName, item: canonicalUrl },
          ],
        },
        {
          '@context': 'https://schema.org',
          '@type': 'Product',
          name: productName,
          ...(view.model ? { model: view.model } : {}),
          ...(reviewedDescription ? { description: reviewedDescription } : {}),
          ...(schemaImages.length ? { image: schemaImages } : {}),
          brand: { '@type': 'Brand', name: 'UTEN' },
          ...(taxonomy.status === 'VERIFIED' ? { category: functionTypes[taxonomy.functionType] } : {}),
          url: canonicalUrl,
        },
      ]} />

      <div className="container-uten py-7 md:py-10">
        <Link locale={locale} href={`/products/${familySlug}`} className="inline-flex min-h-11 items-center gap-2 text-sm font-semibold text-muted-foreground transition hover:text-accent">
          <ArrowLeft className="h-4 w-4 rtl:rotate-180" />{seriesName}
        </Link>
      </div>

      <section className="container-uten pb-16 md:pb-24">
        <VariantViewer
          locale={locale}
          product={{ id: product.id, seriesId: product.seriesId, name: productName, model: view.model, seriesName, description: reviewedDescription, studioHref: product.sceneEnabled && product.variants.some(variant => variant.published && variant.image) && !familySlug.includes('floor') ? '/studio' : undefined }}
          variants={variants}
          initialVariantId={requestedVariant}
          labels={{ variants: t('variants'), gallery: t('gallery'), finish: t('finish'), dimensions: t('dimensions'), specsPending: t('specsPending'), tryOnWall: t('tryOnWall'), askAdvice: t('askAdvice'), displayOnly: t('displayOnly') }}
        />
      </section>

      {view.historicalDescription && <section className="container-uten pb-16"><div className="public-history"><h2>{t('historicalTitle')}</h2><p>{t('historicalNote')}</p><p className="historical-copy">{view.historicalDescription}</p></div></section>}

      {resources.length > 0 && <section className="container-uten pb-16"><div className="public-section-heading"><h2>{resourcesT('downloadTitle')}</h2></div><PublicResourceList resources={resources} locale={locale} /></section>}

      {specs.length > 0 && (
        <section className="border-y border-border bg-background-elevated/55 py-14 md:py-20">
          <div className="container-uten grid gap-8 lg:grid-cols-[1fr_1.1fr]">
            <div>
              <p className="eyebrow">{t('factsEyebrow')}</p>
              <h2 className="mt-5 text-3xl font-semibold md:text-5xl">{t('specs')}</h2>
            </div>
            <dl className="rounded-2xl border border-border bg-card">
              {specs.map((spec, index) => (
                <div key={`${spec.label}-${index}`} className="grid grid-cols-[minmax(120px,.7fr)_1fr] gap-4 border-b border-border px-5 py-4 last:border-b-0">
                  <dt className="text-sm text-muted-foreground">{spec.label}</dt>
                  <dd className="text-sm font-semibold">{spec.value}</dd>
                </div>
              ))}
            </dl>
          </div>
        </section>
      )}

      <section className={specs.length ? 'section-tight' : 'border-y border-border bg-background-elevated/55 py-14 md:py-20'}>
        <div className="container-uten grid gap-8 lg:grid-cols-[1fr_1.1fr]">
          <div>
            <p className="eyebrow">{t('supportEyebrow')}</p>
            <h2 className="mt-5 text-3xl font-semibold md:text-5xl">{t('supportTitle')}</h2>
          </div>
          <div className="rounded-2xl border border-border bg-card">
            {[t('factDataSheet'), t('factSamples'), t('factSupport')].map((item) => (
              <div key={item} className="flex items-start gap-3 border-b border-border px-5 py-4 text-sm last:border-b-0">
                <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0 text-accent" />
                <span>{item}</span>
              </div>
            ))}
          </div>
        </div>
      </section>

      {related.length > 0 && (
        <section className="section-tight">
          <div className="container-uten">
            <div className="mb-8 flex items-end justify-between gap-4">
              <div><p className="eyebrow">{functionTypes[taxonomy.functionType]}</p><h2 className="mt-4 text-3xl font-semibold md:text-5xl">{t('relatedProducts')}</h2></div>
              <Link locale={locale} href={`/products/${familySlug}?function=${encodeURIComponent(taxonomy.functionType)}`} className="btn-ghost hidden sm:inline-flex">{tc('viewAll')}</Link>
            </div>
            <div className="grid grid-cols-2 gap-3 sm:gap-5 lg:grid-cols-3">
              {related.map((item) => (
                <ProductMatrixCard key={item.id} product={item} locale={locale} labels={{ variants: t('variants'), viewDetail: t('viewDetail'), gang: t.raw('gang') as string, functionTypes }} />
              ))}
            </div>
          </div>
        </section>
      )}
    </>
  );
}
