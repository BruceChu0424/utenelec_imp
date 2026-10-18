import { prisma } from './db';
import { publicProductWhere, publicSeriesWhere } from './publication';
import { pickLocale } from './content';
import { BridgeError } from './imp-bridge-security';

/** A browser can select a public record, never author product identity/name. */
export async function resolveInquiryContext(form: FormData, locale: string) {
  const value = (key: string) => String(form.get(key) || '').trim().slice(0, 100);
  const productId = value('productId'), variantId = value('variantId'), seriesId = value('seriesId');
  if (!productId && variantId) throw new BridgeError(400, 'INVALID_PRODUCT_CONTEXT');
  if (productId) {
    const product = await prisma.product.findFirst({ where: publicProductWhere({ id: productId }),
      include: { series: { include: { parent: true } }, variants: { where: { published: true } } } });
    if (!product || (seriesId && product.seriesId !== seriesId && product.series?.parentId !== seriesId)) {
      throw new BridgeError(400, 'PRODUCT_UNAVAILABLE');
    }
    const variant = variantId ? product.variants.find(v => v.id === variantId) : null;
    if (variantId && !variant) throw new BridgeError(400, 'VARIANT_UNAVAILABLE');
    const family = product.series?.parent?.catalogRole === 'FAMILY' ? product.series.parent : product.series;
    const name = pickLocale<{ name?: string }>(product.i18n, locale)?.name || product.model || product.slug;
    const series = pickLocale<{ name?: string }>(family?.i18n, locale)?.name || family?.code || '';
    const familySlug = family?.publicSlug || family?.code;
    return { series, products: [{ id: product.id, name, series, sourceIdentity: product.sourceIdentity,
      variantId: variant?.id ?? null, rowVersion: product.rowVersion }],
      pageUrl: `/${locale}/products/${familySlug}/${product.slug}` };
  }
  if (seriesId) {
    const series = await prisma.series.findFirst({ where: publicSeriesWhere({ id: seriesId }), include: { parent: true } });
    if (!series || (series.catalogRole === 'COLLECTION' && (!series.parent?.published || series.parent.catalogRole !== 'FAMILY'))) {
      throw new BridgeError(400, 'SERIES_UNAVAILABLE');
    }
    const family = series.parent?.catalogRole === 'FAMILY' ? series.parent : series;
    return { series: pickLocale<{ name?: string }>(family.i18n, locale)?.name || family.code,
      seriesId: series.id, products: [], pageUrl: `/${locale}/products/${family.publicSlug || family.code}` };
  }
  return { products: [] };
}
