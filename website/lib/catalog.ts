import type { Prisma, Series } from '@prisma/client';
import type { CatalogProduct } from '@/components/products/ProductExplorer';
import type { StudioScene, StudioVariant } from '@/components/studio/SceneStudio';
import { seriesDisplayName, tr } from './content';
import {
  PRODUCT_FUNCTION_TYPES,
  inferProductTaxonomy,
  isProductClassificationStatus,
  isProductFunctionType,
  type ProductClassificationStatus,
  type ProductFunctionType,
} from './product-taxonomy';
import { STUDIO_DEFAULT_PLACEMENT, normalizeStudioPlacement } from './studio-config';

export type { CatalogProduct } from '@/components/products/ProductExplorer';

type BaseSeries = Series;
type BaseProduct = Prisma.ProductGetPayload<{ include: { variants: true } }>;

/**
 * The public catalog is deployed together with the catalog-v2 Prisma migration.
 * Keeping the new scalar fields explicit here also makes the rendering boundary
 * easy to understand while a developer is regenerating Prisma locally.
 */
export type CatalogSeriesIdentity = BaseSeries & {
  publicSlug?: string | null;
  catalogRole?: string;
};

export type ProductWithRelations = Omit<BaseProduct, 'variants'> & {
  functionType?: string | null;
  gangCount?: number | null;
  controlMode?: string | null;
  configuration?: string | null;
  classificationStatus?: string;
  variants: Array<BaseProduct['variants'][number] & { legacySynthetic?: boolean }>;
  series: (CatalogSeriesIdentity & {
    parent: CatalogSeriesIdentity | null;
  }) | null;
};

export type CatalogSeriesMedia = {
  id: string;
  role: string;
  image: string;
  i18n: string;
  sortOrder: number;
  published: boolean;
};

export type CatalogFamilyProductPreview = {
  id: string;
  slug: string;
  image: string | null;
  i18n: string;
  sortOrder: number;
  functionType?: string | null;
  gangCount?: number | null;
  variants: Array<{ id: string; image: string | null; sortOrder: number }>;
};

export type CatalogCollectionRecord = CatalogSeriesIdentity & {
  parent: CatalogSeriesIdentity | null;
  products: CatalogFamilyProductPreview[];
  _count: { products: number };
};

export type CatalogFamilyRecord = CatalogSeriesIdentity & {
  parent: CatalogSeriesIdentity | null;
  media: CatalogSeriesMedia[];
  products: CatalogFamilyProductPreview[];
  children: CatalogCollectionRecord[];
  _count: { products: number };
};

export type CatalogFamilyImage = {
  src: string;
  kind: 'editorial' | 'product';
};

type RepresentativeProduct = {
  id: string;
  image: string;
  functionType: ProductFunctionType;
  gangCount: number | null;
  sortOrder: number;
};

export type CatalogFamilyView = {
  id: string;
  slug: string;
  legacyCode: string;
  name: string;
  subtitle?: string;
  description?: string;
  count: number;
  images: CatalogFamilyImage[];
  hasEditorialMedia: boolean;
  collections: Array<{ id: string; name: string; count: number }>;
};

function isPublicImage(value: string | null | undefined): value is string {
  return Boolean(value && value.startsWith('/'));
}

export function catalogFamilyForSeries(
  series: (CatalogSeriesIdentity & { parent?: CatalogSeriesIdentity | null }) | null | undefined,
): CatalogSeriesIdentity | null {
  if (!series) return null;
  if (series.catalogRole === 'FAMILY') return series;
  return series.parent || series;
}

export function catalogFamilySlug(
  series: (CatalogSeriesIdentity & { parent?: CatalogSeriesIdentity | null }) | null | undefined,
): string | null {
  const family = catalogFamilyForSeries(series);
  return family ? family.publicSlug || family.code : null;
}

export function catalogSeriesIdentifiers(
  series: (CatalogSeriesIdentity & { parent?: CatalogSeriesIdentity | null }) | null | undefined,
): Set<string> {
  if (!series) return new Set();
  const family = catalogFamilyForSeries(series);
  return new Set(
    [series.code, series.publicSlug, family?.code, family?.publicSlug].filter(
      (value): value is string => Boolean(value),
    ),
  );
}

export function catalogFamilyDisplayName(
  series: (CatalogSeriesIdentity & { parent?: CatalogSeriesIdentity | null }) | null | undefined,
  locale: string,
): string {
  const family = catalogFamilyForSeries(series);
  if (!family) return 'UTEN';
  return tr<{ name?: string }>(family.i18n, locale).name?.trim() || family.code;
}

function previewTaxonomy(product: CatalogFamilyProductPreview): {
  functionType: ProductFunctionType;
  gangCount: number | null;
} {
  const explicitGang = Number.isInteger(product.gangCount) && (product.gangCount || 0) > 0
    ? product.gangCount!
    : null;
  return {
    functionType: isProductFunctionType(product.functionType)
      ? product.functionType
      : 'other',
    gangCount: explicitGang,
  };
}

/**
 * Chooses source-backed products for a FAMILY cover fallback.
 *
 * The cover should explain the breadth of the series at a glance: where the
 * source data allows it, use one-, two- and three-gang controls plus a
 * different function (normally a socket). Families without that combination
 * fall back to distinct functions, then four-gang and stable source order.
 * No product, function or gang value is created by this selector.
 */
export function selectRepresentativeFamilyProducts(
  products: CatalogFamilyProductPreview[],
  limit = 4,
): RepresentativeProduct[] {
  const safeLimit = Math.max(0, Math.min(4, Math.floor(limit)));
  if (!safeLimit) return [];

  const seenImages = new Set<string>();
  const candidates = [...products]
    .sort((left, right) => left.sortOrder - right.sortOrder || left.id.localeCompare(right.id))
    .flatMap((product) => {
      const image = product.variants.find((variant) => isPublicImage(variant.image))?.image
        || product.image;
      if (!isPublicImage(image) || seenImages.has(image)) return [];
      seenImages.add(image);
      const taxonomy = previewTaxonomy(product);
      return [{
        id: product.id,
        image,
        functionType: taxonomy.functionType,
        gangCount: taxonomy.gangCount,
        sortOrder: product.sortOrder,
      }];
    });

  const selected: RepresentativeProduct[] = [];
  const selectedIds = new Set<string>();
  const selectFirst = (predicate: (candidate: RepresentativeProduct) => boolean) => {
    if (selected.length >= safeLimit) return;
    const match = candidates.find((candidate) => !selectedIds.has(candidate.id) && predicate(candidate));
    if (!match) return;
    selected.push(match);
    selectedIds.add(match.id);
  };

  const hasDifferentFunction = candidates.some((candidate) =>
    candidate.functionType !== 'switches' && candidate.functionType !== 'other');
  const gangSlots = hasDifferentFunction ? Math.max(0, safeLimit - 1) : safeLimit;

  // A familiar 1/2/3-gang progression communicates a switch family more
  // clearly than four near-identical records selected only by database order.
  for (const gangCount of [1, 2, 3, 4].slice(0, gangSlots)) {
    selectFirst((candidate) => candidate.functionType === 'switches' && candidate.gangCount === gangCount);
  }

  // Reserve space for real functional breadth. The stable taxonomy order puts
  // power sockets first, matching how a switch-and-socket family is understood.
  for (const functionType of PRODUCT_FUNCTION_TYPES) {
    if (functionType === 'switches' || functionType === 'other') continue;
    selectFirst((candidate) => candidate.functionType === functionType);
  }

  // If preferred switch gangs were absent, use any other source-backed gang
  // before falling back to the original product order.
  for (const gangCount of [1, 2, 3, 4]) {
    selectFirst((candidate) => candidate.gangCount === gangCount);
  }
  for (const functionType of PRODUCT_FUNCTION_TYPES) {
    selectFirst((candidate) => candidate.functionType === functionType);
  }
  for (const candidate of candidates) {
    selectFirst((item) => item.id === candidate.id);
  }

  return selected;
}

export function toCatalogFamily(family: CatalogFamilyRecord, locale: string): CatalogFamilyView {
  const content = tr<{ name?: string; subtitle?: string; description?: string }>(family.i18n, locale);
  const rolePriority = (role: string) => {
    const normalized = role.toLocaleUpperCase();
    if (normalized === 'COMBINATION' || normalized === 'COVER') return 0;
    if (normalized === 'HERO') return 1;
    if (normalized === 'EFFECT' || normalized === 'LIFESTYLE') return 2;
    return 3;
  };
  const publishedMedia = family.media
    .filter((item) => item.published && isPublicImage(item.image))
    .sort((a, b) => rolePriority(a.role) - rolePriority(b.role) || a.sortOrder - b.sortOrder || a.id.localeCompare(b.id));
  const explicitCombinationCover = publishedMedia.find((item) => rolePriority(item.role) === 0)?.image;
  // Only a deliberately curated combination/cover asset may replace the
  // generated family collage. Hero, lifestyle and detail media describe the
  // series elsewhere; treating one of them as the card cover would change the
  // meaning of the user's "series combination cover" field.
  const editorialCover = explicitCombinationCover
    || (isPublicImage(family.coverImage) ? family.coverImage : undefined);
  const previews = [...family.products, ...family.children.flatMap((child) => child.products)]
    .sort((a, b) => a.sortOrder - b.sortOrder || a.id.localeCompare(b.id));
  const representativeProducts = selectRepresentativeFamilyProducts(previews);
  const images: CatalogFamilyImage[] = editorialCover
    ? [{ src: editorialCover, kind: 'editorial' }]
    : representativeProducts.map((product) => ({ src: product.image, kind: 'product' }));

  return {
    id: family.id,
    slug: family.publicSlug || family.code,
    legacyCode: family.code,
    name: content.name?.trim() || family.code,
    subtitle: content.subtitle?.trim() || undefined,
    description: content.description?.trim() || undefined,
    count: family._count.products + family.children.reduce((total, child) => total + child._count.products, 0),
    images,
    hasEditorialMedia: Boolean(editorialCover),
    collections: family.children
      .map((child) => ({
        id: child.id,
        name: tr<{ name?: string }>(child.i18n, locale).name?.trim() || seriesDisplayName(child, locale),
        count: child._count.products,
      }))
      .filter((child) => child.count > 0),
  };
}

export function resolveProductTaxonomy(product: ProductWithRelations, locale: string): {
  functionType: ProductFunctionType;
  gangCount: number | null;
  controlMode: string | null;
  status: ProductClassificationStatus;
} {
  const localized = tr<{ name?: string }>(product.i18n, locale);
  const sourceZh = tr<{ name?: string }>(product.i18n, 'zh');
  const sourceEn = tr<{ name?: string }>(product.i18n, 'en');
  const collectionNames = product.series
    ? [
        seriesDisplayName(product.series, locale),
        seriesDisplayName(product.series, 'zh'),
        seriesDisplayName(product.series, 'en'),
      ]
    : [];
  const inferred = inferProductTaxonomy(
    [localized.name, sourceZh.name, sourceEn.name, product.model],
    collectionNames,
  );
  const explicitGang = Number.isInteger(product.gangCount) && (product.gangCount || 0) > 0
    ? product.gangCount
    : null;

  return {
    functionType: isProductFunctionType(product.functionType) ? product.functionType : inferred.functionType,
    gangCount: explicitGang ?? inferred.gangCount,
    controlMode: product.controlMode?.trim() || inferred.controlMode,
    status: isProductClassificationStatus(product.classificationStatus)
      ? product.classificationStatus
      : inferred.status,
  };
}

export function toCatalogProduct(product: ProductWithRelations, locale: string, standardName = 'Standard'): CatalogProduct {
  const content = tr<{ name?: string; description?: string }>(product.i18n, locale);
  const familySlug = catalogFamilySlug(product.series);
  const seriesName = catalogFamilyDisplayName(product.series, locale);
  const collectionName = product.series
    ? tr<{ name?: string }>(product.series.i18n, locale).name?.trim() || seriesDisplayName(product.series, locale)
    : undefined;
  const taxonomy = resolveProductTaxonomy(product, locale);
  const isReviewed = taxonomy.status === 'VERIFIED';
  const variants = product.variants
    .filter((variant) => variant.published && variant.image)
    .map((variant) => ({
      id: variant.id,
      name: tr<{ name?: string }>(variant.i18n, locale).name || variant.sku || standardName,
      image: variant.image!,
      swatchHex: isReviewed ? variant.swatchHex : null,
    }));

  if (!variants.length && product.image) {
    variants.push({
      id: `${product.id}-default`,
      name: standardName,
      image: product.image,
      swatchHex: null,
    });
  }

  return {
    id: product.id,
    name: content.name || product.model || product.slug,
    model: isReviewed ? product.model : null,
    category: isReviewed ? product.category : null,
    description: isReviewed ? content.description : undefined,
    href: familySlug ? `/products/${familySlug}/${product.slug}` : '/products',
    seriesCode: familySlug || undefined,
    seriesName,
    collectionName,
    image: product.image,
    variants,
    functionType: taxonomy.functionType,
    gangCount: taxonomy.gangCount,
    controlMode: isReviewed ? taxonomy.controlMode : null,
    configuration: isReviewed ? product.configuration?.trim() || null : null,
    classificationStatus: taxonomy.status,
  };
}

export function toStudioVariants(products: ProductWithRelations[], locale: string, standardName = 'Standard'): StudioVariant[] {
  return products.flatMap((product) => {
    const content = tr<{ name?: string }>(product.i18n, locale);
    const seriesName = catalogFamilyDisplayName(product.series, locale);
    const productName = content.name || product.model || product.slug;
    const familySlug = catalogFamilySlug(product.series);
    const baseProductHref = familySlug ? `/products/${familySlug}/${product.slug}` : '/products';
    const variants = product.variants
      .filter((variant) => variant.published && variant.image)
      .map((variant) => {
        const localizedName = tr<{ name?: string }>(variant.i18n, locale).name || variant.sku || standardName;
        const sourceNames = [
          tr<{ name?: string }>(variant.i18n, 'zh').name,
          tr<{ name?: string }>(variant.i18n, 'en').name,
        ].filter((value): value is string => Boolean(value)).map((value) => value.trim().toLocaleLowerCase());
        const legacySynthetic = Boolean(variant.legacySynthetic) || (
          !variant.sourceIdentity
          && !variant.sku
          && !variant.swatchHex
          && !variant.finish
          && !variant.widthMm
          && !variant.heightMm
          && !variant.depthMm
          && sourceNames.every((name) => name === 'standard' || name === '标准款')
        );
        return {
          id: variant.id,
          name: localizedName,
          productName,
          model: legacySynthetic ? null : product.model || variant.sku,
          image: variant.image!,
          swatchHex: legacySynthetic ? null : variant.swatchHex,
          finish: legacySynthetic ? null : variant.finish,
          widthMm: legacySynthetic ? null : variant.widthMm,
          heightMm: legacySynthetic ? null : variant.heightMm,
          seriesName,
          productHref: `${baseProductHref}?variant=${encodeURIComponent(variant.id)}`,
          legacySynthetic,
        };
      });

    if (!variants.length && product.image) {
      const fallbackId = `${product.id}-default`;
      variants.push({
        id: fallbackId,
        name: standardName,
        productName,
        model: product.model,
        image: product.image,
        swatchHex: null,
        finish: null,
        widthMm: null,
        heightMm: null,
        seriesName,
        productHref: `${baseProductHref}?variant=${encodeURIComponent(fallbackId)}`,
        legacySynthetic: true,
      });
    }
    return variants;
  });
}

export function toStudioScene(
  scene: {
    id: string;
    slug: string;
    i18n: string;
    backgroundImage: string;
    config: string;
    defaultVariantId?: string | null;
  },
  locale: string,
): StudioScene {
  const content = tr<{ name?: string; description?: string }>(scene.i18n, locale);
  let placement = { ...STUDIO_DEFAULT_PLACEMENT };
  let legacyDefaultVariantId: string | undefined;

  try {
    const config = JSON.parse(scene.config || '{}') as {
      schemaVersion?: unknown;
      defaultVariantId?: unknown;
      placement?: { x?: unknown; y?: unknown; scale?: unknown; rotation?: unknown };
    };
    placement = normalizeStudioPlacement(config.placement);
    legacyDefaultVariantId =
      typeof config.defaultVariantId === 'string' ? config.defaultVariantId : undefined;
  } catch {
    // Invalid legacy JSON must not make the public studio unavailable.
  }

  return {
    id: scene.id,
    slug: scene.slug,
    name: content.name || scene.slug,
    description: content.description,
    image: scene.backgroundImage,
    placement,
    defaultVariantId: scene.defaultVariantId || legacyDefaultVariantId,
  };
}
