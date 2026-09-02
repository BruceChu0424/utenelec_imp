import { inferProductTaxonomy } from '../../lib/product-taxonomy';

export const FAMILY_PUBLIC_SLUGS = Object.freeze({
  '1': 'v1-0',
  '2': 'v1-1',
  '3': 'v2-0',
  '4': 'v3-0',
  '5': 'v4-0',
  '6': 'v5-0',
  '7': 'v6-0',
  '9': 'v7-0',
  '10': 'v8-0',
  '11': 'v9-0',
  '12': 'v9-1',
  '53': 'floor-socket',
  '54': 'v1-2',
  '61': 'a6-0',
  '70': 'q7',
  '75': 'q9',
  '76': 'q3',
  '77': 'v4-white',
  '78': 'a5',
  '79': 'a8',
  '80': 's300',
  '81': 'z9',
} as const);

export const CONTAINER_SOURCE_ID = '60';
export const SOURCE_SYSTEM = 'ch-uten-v2';

export type SeriesSnapshot = {
  id: string;
  parentId: string | null;
  sourceIdentity: string | null;
  i18n: string;
  publicSlug: string | null;
  catalogRole: string;
  published: boolean;
  rowVersion: number;
};

export type ProductSnapshot = {
  id: string;
  seriesId: string | null;
  i18n: string;
  functionType: string | null;
  gangCount: number | null;
  controlMode: string | null;
  classificationStatus: string;
  published: boolean;
  rowVersion: number;
};

export type VariantSnapshot = {
  id: string;
  productId: string;
  sourceIdentity: string | null;
  legacySynthetic: boolean;
  dataStatus: string;
  isDefault: boolean;
};

export type CatalogNormalizationInput = {
  series: SeriesSnapshot[];
  products: ProductSnapshot[];
  variants: VariantSnapshot[];
};

export type SeriesNormalization = {
  id: string;
  sourceId: string | null;
  expectedRowVersion: number;
  data: {
    publicSlug?: string | null;
    catalogRole?: 'FAMILY' | 'COLLECTION' | 'CONTAINER';
    published?: boolean;
  };
  reasons: string[];
};

export type ProductNormalization = {
  id: string;
  expectedRowVersion: number;
  data: {
    functionType?: string;
    gangCount?: number;
    controlMode?: string;
    classificationStatus?: 'INFERRED' | 'NEEDS_REVIEW';
  };
};

export type VariantNormalization = {
  id: string;
  productId: string;
  data: {
    legacySynthetic?: true;
    dataStatus?: 'NEEDS_REVIEW';
    isDefault?: true;
  };
};

export type CatalogNormalizationPlan = {
  seriesUpdates: SeriesNormalization[];
  productUpdates: ProductNormalization[];
  variantUpdates: VariantNormalization[];
  issues: string[];
  summary: {
    familyCount: number;
    collectionCount: number;
    containerCount: number;
    familiesToPublish: number;
    productsInferred: number;
    productsNeedingReview: number;
    legacySyntheticVariants: number;
  };
};

function sourceSeriesId(identity: string | null): string | null {
  if (!identity) return null;
  const match = identity.match(new RegExp(`^${SOURCE_SYSTEM}:series:(\\d+)$`, 'u'));
  return match?.[1] ?? null;
}

function localizedNames(value: string): string[] {
  try {
    const parsed = JSON.parse(value) as unknown;
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return [];
    return Object.values(parsed).flatMap((locale) => {
      if (!locale || typeof locale !== 'object' || Array.isArray(locale)) return [];
      const name = (locale as { name?: unknown }).name;
      return typeof name === 'string' && name.trim() ? [name.trim()] : [];
    });
  } catch {
    return [];
  }
}

function hasOwnChanges(value: Record<string, unknown>): boolean {
  return Object.keys(value).length > 0;
}

function isLegacyBaseVariant(identity: string | null): boolean {
  return Boolean(identity && new RegExp(`^${SOURCE_SYSTEM}:variant:[^:]+:base$`, 'u').test(identity));
}

export function buildCatalogNormalizationPlan(input: CatalogNormalizationInput): CatalogNormalizationPlan {
  const issues: string[] = [];
  const seriesById = new Map(input.series.map((item) => [item.id, item]));
  const children = new Map<string, string[]>();
  for (const item of input.series) {
    if (!item.parentId) continue;
    children.set(item.parentId, [...(children.get(item.parentId) ?? []), item.id]);
  }

  const directPublishedProductSeries = new Set(
    input.products.filter((item) => item.published && item.seriesId).map((item) => item.seriesId as string),
  );
  const directProductSeries = new Set(
    input.products.filter((item) => item.seriesId).map((item) => item.seriesId as string),
  );
  const subtreeHasPublishedProduct = (rootId: string): boolean => {
    const pending = [rootId];
    const visited = new Set<string>();
    while (pending.length) {
      const current = pending.pop();
      if (!current || visited.has(current)) continue;
      visited.add(current);
      if (directPublishedProductSeries.has(current)) return true;
      pending.push(...(children.get(current) ?? []));
    }
    return false;
  };

  const updatesBySeriesId = new Map<string, SeriesNormalization>();
  const collectionIds = new Set<string>();
  const ensureSeriesUpdate = (item: SeriesSnapshot, sourceId: string | null) => {
    const existing = updatesBySeriesId.get(item.id);
    if (existing) return existing;
    const created: SeriesNormalization = {
      id: item.id,
      sourceId,
      expectedRowVersion: item.rowVersion,
      data: {},
      reasons: [],
    };
    updatesBySeriesId.set(item.id, created);
    return created;
  };

  const familyIds = new Set<string>();
  for (const item of input.series) {
    const sourceId = sourceSeriesId(item.sourceIdentity);
    const familySlug = sourceId ? FAMILY_PUBLIC_SLUGS[sourceId as keyof typeof FAMILY_PUBLIC_SLUGS] : undefined;
    if (familySlug) {
      familyIds.add(item.id);
      const update = ensureSeriesUpdate(item, sourceId);
      if (item.catalogRole !== 'FAMILY') update.data.catalogRole = 'FAMILY';
      if (item.publicSlug !== familySlug) update.data.publicSlug = familySlug;
      if (!item.published && subtreeHasPublishedProduct(item.id)) {
        update.data.published = true;
        update.reasons.push('contains an already-published direct or descendant product');
      }
      update.reasons.push('confirmed source-backed family');
      continue;
    }
    if (sourceId === CONTAINER_SOURCE_ID) {
      const update = ensureSeriesUpdate(item, sourceId);
      if (item.catalogRole !== 'CONTAINER') update.data.catalogRole = 'CONTAINER';
      if (item.publicSlug !== null) update.data.publicSlug = null;
      if (item.published) update.data.published = false;
      update.reasons.push('confirmed non-public structural container');
    }
  }

  for (const familyId of familyIds) {
    for (const childId of children.get(familyId) ?? []) {
      if (!directProductSeries.has(childId) || familyIds.has(childId)) continue;
      const child = seriesById.get(childId);
      if (!child) continue;
      collectionIds.add(childId);
      const update = ensureSeriesUpdate(child, sourceSeriesId(child.sourceIdentity));
      if (child.catalogRole !== 'COLLECTION') update.data.catalogRole = 'COLLECTION';
      update.reasons.push('direct product-bearing child of a confirmed family');
    }
  }

  const targetSlugOwners = new Map<string, string>();
  for (const item of input.series) {
    if (item.publicSlug) targetSlugOwners.set(item.publicSlug, item.id);
  }
  for (const update of updatesBySeriesId.values()) {
    if (typeof update.data.publicSlug !== 'string') continue;
    const owner = targetSlugOwners.get(update.data.publicSlug);
    if (owner && owner !== update.id) {
      issues.push(`publicSlug ${update.data.publicSlug} is already owned by series ${owner}; target is ${update.id}`);
    }
  }

  const seriesNames = new Map(input.series.map((item) => [item.id, localizedNames(item.i18n)]));
  const productUpdates: ProductNormalization[] = [];
  for (const product of input.products) {
    if (product.classificationStatus === 'VERIFIED') continue;
    const collectionNames: string[] = [];
    const visited = new Set<string>();
    let cursor = product.seriesId;
    while (cursor && !visited.has(cursor)) {
      visited.add(cursor);
      collectionNames.push(...(seriesNames.get(cursor) ?? []));
      cursor = seriesById.get(cursor)?.parentId ?? null;
    }
    const inferred = inferProductTaxonomy(localizedNames(product.i18n), collectionNames);
    const data: ProductNormalization['data'] = {};
    if (!product.functionType && inferred.functionType !== 'other') data.functionType = inferred.functionType;
    if (product.gangCount === null && inferred.gangCount !== null) data.gangCount = inferred.gangCount;
    if (!product.controlMode && inferred.controlMode) data.controlMode = inferred.controlMode;
    const nextStatus = inferred.status === 'INFERRED' ? 'INFERRED' : 'NEEDS_REVIEW';
    if (product.classificationStatus !== nextStatus) data.classificationStatus = nextStatus;
    if (hasOwnChanges(data)) {
      productUpdates.push({ id: product.id, expectedRowVersion: product.rowVersion, data });
    }
  }

  const variantsByProduct = new Map<string, VariantSnapshot[]>();
  for (const variant of input.variants) {
    variantsByProduct.set(variant.productId, [...(variantsByProduct.get(variant.productId) ?? []), variant]);
  }
  const variantUpdates: VariantNormalization[] = [];
  for (const variant of input.variants) {
    if (!isLegacyBaseVariant(variant.sourceIdentity)) continue;
    const data: VariantNormalization['data'] = {};
    if (!variant.legacySynthetic) data.legacySynthetic = true;
    if (variant.dataStatus !== 'NEEDS_REVIEW') data.dataStatus = 'NEEDS_REVIEW';
    if (!variant.isDefault && variantsByProduct.get(variant.productId)?.length === 1) data.isDefault = true;
    if (hasOwnChanges(data)) variantUpdates.push({ id: variant.id, productId: variant.productId, data });
  }

  const productUpdatesById = new Set(productUpdates.map((item) => item.id));
  for (const productId of new Set(variantUpdates.map((item) => item.productId))) {
    if (productUpdatesById.has(productId)) continue;
    const product = input.products.find((item) => item.id === productId);
    if (!product) {
      issues.push(`variant normalization references missing product ${productId}`);
      continue;
    }
    productUpdates.push({ id: product.id, expectedRowVersion: product.rowVersion, data: {} });
    productUpdatesById.add(product.id);
  }

  const seriesUpdates = [...updatesBySeriesId.values()].filter((item) => hasOwnChanges(item.data));
  return {
    seriesUpdates,
    productUpdates,
    variantUpdates,
    issues,
    summary: {
      familyCount: input.series.filter((item) => {
        const sourceId = sourceSeriesId(item.sourceIdentity);
        return Boolean(sourceId && FAMILY_PUBLIC_SLUGS[sourceId as keyof typeof FAMILY_PUBLIC_SLUGS]);
      }).length,
      collectionCount: collectionIds.size,
      containerCount: input.series.filter((item) => sourceSeriesId(item.sourceIdentity) === CONTAINER_SOURCE_ID).length,
      familiesToPublish: seriesUpdates.filter((item) => item.data.catalogRole === 'FAMILY' && item.data.published === true).length,
      productsInferred: productUpdates.filter((item) => item.data.classificationStatus === 'INFERRED').length,
      productsNeedingReview: input.products.filter((item) => {
        const update = productUpdates.find((candidate) => candidate.id === item.id);
        return (update?.data.classificationStatus ?? item.classificationStatus) === 'NEEDS_REVIEW';
      }).length,
      legacySyntheticVariants: input.variants.filter((item) => isLegacyBaseVariant(item.sourceIdentity)).length,
    },
  };
}
