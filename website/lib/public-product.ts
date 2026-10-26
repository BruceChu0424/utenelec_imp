import type { ProductWithRelations } from './catalog';
import { pick, tr } from './content';
import { isProductFunctionType } from './product-taxonomy';

function images(value: string | null | undefined): string[] {
  try { const parsed: unknown = JSON.parse(value || '[]'); return Array.isArray(parsed) ? parsed.filter((item): item is string => typeof item === 'string' && item.startsWith('/') && !item.startsWith('//')) : []; } catch { return []; }
}
function publicImage(value: string | null | undefined): value is string { return Boolean(value?.startsWith('/') && !value.startsWith('//')); }
function positive(value: number | null | undefined) { return typeof value === 'number' && Number.isFinite(value) && value > 0 ? value : null; }

/** One boundary for cards, details and room previews. Historical plain text
 * stays available as history while unreviewed attributes never become specs. */
export function publicProductView(product: ProductWithRelations, locale: string, standardName = 'Standard') {
  const content = tr<{ name?: string; description?: string }>(product.i18n, locale);
  const reviewed = product.classificationStatus === 'VERIFIED';
  const historical = Boolean(product.legacySource || product.sourceIdentity?.startsWith('ch-uten-v2:'));
  const variants = product.variants.filter(variant => variant.published && publicImage(variant.image)).map(variant => {
    const names = [tr<{ name?: string }>(variant.i18n, 'zh').name, tr<{ name?: string }>(variant.i18n, 'en').name].filter(Boolean);
    const synthetic = Boolean(variant.legacySynthetic) || (!variant.sourceIdentity && !variant.sku && !variant.swatchHex && !variant.finish && !variant.widthMm && !variant.heightMm && !variant.depthMm && names.every(name => name === '标准款' || name?.toLowerCase() === 'standard'));
    const verified = reviewed && !synthetic && variant.dataStatus === 'VERIFIED';
    return {
      id: variant.id,
      name: tr<{ name?: string }>(variant.i18n, locale).name || standardName,
      image: variant.image!,
      gallery: [...new Set([variant.image!, ...images(variant.gallery)])],
      swatchHex: verified ? variant.swatchHex : null,
      finish: verified ? variant.finish : null,
      widthMm: verified ? positive(variant.widthMm) : null,
      heightMm: verified ? positive(variant.heightMm) : null,
      depthMm: verified ? positive(variant.depthMm) : null,
      legacySynthetic: synthetic,
      verified,
    };
  });
  if (!variants.length && publicImage(product.image)) variants.push({ id: `${product.id}-default`, name: standardName, image: product.image, gallery: [...new Set([product.image, ...images(product.gallery)])], swatchHex: null, finish: null, widthMm: null, heightMm: null, depthMm: null, legacySynthetic: true, verified: false });
  const rawSpecs = reviewed ? pick<Array<{ label?: string; value?: string }>>(product.specs, locale) : null;
  const specs = Array.isArray(rawSpecs) ? rawSpecs.filter((item): item is { label: string; value: string } => typeof item?.label === 'string' && typeof item.value === 'string' && Boolean(item.label.trim() && item.value.trim())) : [];
  return {
    id: product.id, slug: product.slug, name: content.name?.trim() || product.slug,
    model: reviewed ? product.model : null, category: reviewed ? product.category : null,
    description: reviewed ? content.description : undefined,
    historicalDescription: historical ? content.description : undefined,
    historical, reviewed, specs, variants,
    image: publicImage(product.image) ? product.image : variants[0]?.image || null,
    functionType: isProductFunctionType(product.functionType) ? product.functionType : 'other' as const,
    gangCount: Number.isInteger(product.gangCount) ? positive(product.gangCount) : null,
    controlMode: reviewed ? product.controlMode : null,
    configuration: reviewed ? product.configuration : null,
  };
}

export function productContactHref(context: { productId?: string; variantId?: string | null; seriesId?: string | null }, source: 'product' | 'studio' = 'product') {
  const params = new URLSearchParams({ source });
  if (context.productId) params.set('productId', context.productId);
  if (context.variantId && !context.variantId.endsWith('-default')) params.set('variantId', context.variantId);
  if (context.seriesId) params.set('seriesId', context.seriesId);
  return `/contact?${params}`;
}
