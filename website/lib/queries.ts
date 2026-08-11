import type { Prisma } from '@prisma/client';
import { cache } from 'react';
import {
  type CatalogFamilyRecord,
  type CatalogProduct,
  type ProductWithRelations,
  toCatalogProduct,
} from './catalog';
import { PRODUCT_FUNCTION_TYPES, type ProductFunctionType } from './product-taxonomy';
import { prisma } from './db';
import { publicNewsWhere, publicProductWhere } from './publication';

export const getSeries = () =>
  prisma.series.findMany({
    where: { published: true },
    orderBy: { sortOrder: 'asc' },
    include: {
      parent: true,
      _count: { select: { products: { where: { published: true } } } },
    },
  });

export const getSeriesByCode = (code: string) =>
  prisma.series.findFirst({
    where: { code, published: true },
    include: {
      parent: true,
      _count: { select: { products: { where: { published: true } } } },
    },
  });

const productPreviewSelection = {
  where: { published: true },
  orderBy: [{ sortOrder: 'asc' }, { createdAt: 'desc' }],
  // Cover selection needs a representative candidate pool, not merely the
  // first four database rows (which are commonly four adjacent switch gangs).
  // Only lightweight identity/taxonomy/image fields are loaded here.
  take: 96,
  select: {
    id: true,
    slug: true,
    image: true,
    i18n: true,
    sortOrder: true,
    functionType: true,
    gangCount: true,
    variants: {
      where: { published: true, image: { not: null } },
      orderBy: { sortOrder: 'asc' },
      take: 1,
      select: { id: true, image: true, sortOrder: true },
    },
  },
} as const;

/**
 * Marketing families are the only records exposed as top-level catalog
 * destinations. The UNCLASSIFIED root fallback keeps imported V families
 * visible before the one-time classification migration has been reviewed.
 */
export const getCatalogFamilies = cache(async (): Promise<CatalogFamilyRecord[]> => {
  const records = await prisma.series.findMany({
    where: {
      OR: [
        { catalogRole: 'FAMILY', published: true },
        {
          catalogRole: 'UNCLASSIFIED',
          published: true,
          parentId: null,
          OR: [
            { products: { some: { published: true } } },
            { children: { some: { published: true, products: { some: { published: true } } } } },
          ],
        },
      ],
    },
    orderBy: [{ sortOrder: 'asc' }, { createdAt: 'asc' }],
    include: {
      parent: true,
      media: {
        where: { published: true },
        orderBy: [{ sortOrder: 'asc' }, { id: 'asc' }],
      },
      products: productPreviewSelection,
      children: {
        where: {
          published: true,
          OR: [{ catalogRole: 'COLLECTION' }, { catalogRole: 'UNCLASSIFIED' }],
        },
        orderBy: [{ sortOrder: 'asc' }, { createdAt: 'asc' }],
        include: {
          parent: true,
          products: productPreviewSelection,
          _count: { select: { products: { where: { published: true } } } },
        },
      },
      _count: { select: { products: { where: { published: true } } } },
    },
  } as never);
  return records as unknown as CatalogFamilyRecord[];
});

export type CatalogFamilyResolution = {
  family: CatalogFamilyRecord;
  canonicalSlug: string;
  matchedCollectionId?: string;
};

export async function resolveCatalogFamily(identifier: string): Promise<CatalogFamilyResolution | null> {
  const normalized = identifier.trim().toLocaleLowerCase();
  if (!normalized) return null;
  const families = await getCatalogFamilies();
  for (const family of families) {
    const canonicalSlug = family.publicSlug || family.code;
    if ([family.code, family.publicSlug].some((value) => value?.toLocaleLowerCase() === normalized)) {
      return { family, canonicalSlug };
    }
    const collection = family.children.find((child) =>
      [child.code, child.publicSlug].some((value) => value?.toLocaleLowerCase() === normalized),
    );
    if (collection) return { family, canonicalSlug, matchedCollectionId: collection.id };
  }
  return null;
}

export function catalogFamilySeriesIds(family: CatalogFamilyRecord): string[] {
  return [family.id, ...family.children.map((child) => child.id)];
}

export const getProducts = (opts: { seriesId?: string; take?: number; featured?: boolean } = {}) =>
  prisma.product.findMany({
    where: publicProductWhere({
      ...(opts.seriesId ? { seriesId: opts.seriesId } : {}),
      ...(opts.featured ? { featured: true } : {}),
    }),
    orderBy: [{ sortOrder: 'asc' }, { createdAt: 'desc' }],
    ...(opts.take ? { take: opts.take } : {}),
    include: { series: { include: { parent: true } }, variants: { where: { published: true }, orderBy: [{ isDefault: 'desc' }, { sortOrder: 'asc' }] } },
  });

export const getProductCount = (seriesId?: string) =>
  prisma.product.count({
    where: publicProductWhere(seriesId ? { seriesId } : {}),
  });

export const getProductVariantCount = (seriesId?: string) =>
  prisma.productVariant.count({
    where: {
      published: true,
      product: { is: publicProductWhere(seriesId ? { seriesId } : {}) },
    },
  });

export const getProductBySlug = (slug: string) =>
  prisma.product.findFirst({
    where: publicProductWhere({ slug }),
    include: { series: { include: { parent: true } }, variants: { where: { published: true }, orderBy: [{ isDefault: 'desc' }, { sortOrder: 'asc' }] } },
  });

export type CatalogQueryInput = {
  locale: string;
  familyIdentifier: string;
  query?: string;
  functionType?: ProductFunctionType | null;
  gangCount?: number | null;
  offset?: number;
  take?: number;
  standardName?: string;
};

export type CatalogQueryResult = {
  products: CatalogProduct[];
  total: number;
  canonicalSlug: string;
  facets: {
    functions: Array<{ value: ProductFunctionType; count: number }>;
    gangs: Array<{ value: number; count: number }>;
  };
};

/** Shared RSC/API catalog query. Null taxonomy fields are retained for the
 * conservative inference fallback; explicit conflicting classifications are
 * excluded in SQL before the in-memory review-candidate check. */
export async function queryCatalogProducts(input: CatalogQueryInput): Promise<CatalogQueryResult | null> {
  const resolution = await resolveCatalogFamily(input.familyIdentifier);
  if (!resolution) return null;
  const query = input.query?.trim().slice(0, 80) || '';
  const seriesIds = catalogFamilySeriesIds(resolution.family);
  const taxonomyFilters: Array<Record<string, unknown>> = [];
  if (input.functionType) {
    taxonomyFilters.push({
      OR: [{ functionType: input.functionType }, { functionType: null }],
    });
  }
  if (input.gangCount) {
    taxonomyFilters.push({
      OR: [{ gangCount: input.gangCount }, { gangCount: null }],
    });
  }
  const extraWhere = {
    seriesId: { in: seriesIds },
    ...(taxonomyFilters.length ? { AND: taxonomyFilters } : {}),
    ...(query
      ? {
          OR: [
            { model: { contains: query } },
            { category: { contains: query } },
            { i18n: { contains: query } },
            { variants: { some: { i18n: { contains: query }, published: true } } },
            { variants: { some: { sku: { contains: query }, published: true } } },
          ],
        }
      : {}),
  } as unknown as Prisma.ProductWhereInput;
  const records = await prisma.product.findMany({
    where: publicProductWhere(extraWhere),
    orderBy: [{ sortOrder: 'asc' }, { createdAt: 'desc' }],
    include: {
      series: { include: { parent: true } },
      variants: { where: { published: true }, orderBy: [{ isDefault: 'desc' }, { sortOrder: 'asc' }] },
    },
  });
  const mapped = (records as unknown as ProductWithRelations[]).map((product) =>
    toCatalogProduct(product, input.locale, input.standardName),
  );
  const functionCounts = new Map<ProductFunctionType, number>();
  const gangCounts = new Map<number, number>();
  for (const product of mapped) {
    functionCounts.set(product.functionType, (functionCounts.get(product.functionType) || 0) + 1);
    if (product.gangCount) gangCounts.set(product.gangCount, (gangCounts.get(product.gangCount) || 0) + 1);
  }
  const filtered = mapped
    .filter((product) => !input.functionType || product.functionType === input.functionType)
    .filter((product) => !input.gangCount || product.gangCount === input.gangCount)
    .sort((left, right) => {
      const functionOrder = PRODUCT_FUNCTION_TYPES.indexOf(left.functionType) - PRODUCT_FUNCTION_TYPES.indexOf(right.functionType);
      if (functionOrder) return functionOrder;
      const leftGang = left.gangCount ?? Number.MAX_SAFE_INTEGER;
      const rightGang = right.gangCount ?? Number.MAX_SAFE_INTEGER;
      if (leftGang !== rightGang) return leftGang - rightGang;
      return (left.model || left.name).localeCompare(right.model || right.name, input.locale, { numeric: true });
    });
  const offset = Math.max(0, Math.min(5000, input.offset || 0));
  const take = Math.max(1, Math.min(5000, input.take || 24));

  return {
    products: filtered.slice(offset, offset + take),
    total: filtered.length,
    canonicalSlug: resolution.canonicalSlug,
    facets: {
      functions: PRODUCT_FUNCTION_TYPES
        .map((value) => ({ value, count: functionCounts.get(value) || 0 }))
        .filter((item) => item.count > 0),
      gangs: Array.from(gangCounts, ([value, count]) => ({ value, count })).sort((a, b) => a.value - b.value),
    },
  };
}

/** Latest products for the home page. */
export const getLatestProducts = (take = 4) =>
  prisma.product.findMany({
    where: publicProductWhere({ image: { not: null } }),
    // `featured` selects the current launch/spotlight set. Product sortOrder is
    // the explicit CMS sequence (and therefore also selects the hero); newly
    // created products fill any remaining slots without copy edits reshuffling it.
    orderBy: [{ featured: 'desc' }, { sortOrder: 'asc' }, { createdAt: 'desc' }, { id: 'desc' }],
    take,
    include: { series: { include: { parent: true } }, variants: { where: { published: true }, orderBy: [{ isDefault: 'desc' }, { sortOrder: 'asc' }] } },
  });

/** Public products and concrete variants enabled for the room studio. */
export const getSceneProducts = () =>
  prisma.product.findMany({
    where: publicProductWhere({
      sceneEnabled: true,
      variants: { some: { published: true, image: { not: null } } },
    }),
    orderBy: [{ sortOrder: 'asc' }, { createdAt: 'desc' }],
    include: {
      series: { include: { parent: true } },
      variants: {
        where: { published: true, image: { not: null } },
        orderBy: [{ isDefault: 'desc' }, { sortOrder: 'asc' }],
      },
    },
  });

/** Only published scene presets are visible in the public studio. */
export const getScenePresets = () =>
  prisma.scenePreset.findMany({
    where: { published: true },
    orderBy: [{ sortOrder: 'asc' }, { createdAt: 'asc' }],
  });

export const getNewsList = (take?: number) =>
  prisma.news.findMany({
    where: publicNewsWhere(),
    orderBy: { publishedAt: 'desc' },
    ...(take ? { take } : {}),
  });

export const getNewsBySlug = (slug: string) => prisma.news.findFirst({ where: publicNewsWhere({ slug }) });

export const getCases = () =>
  prisma.caseItem.findMany({ where: { published: true }, orderBy: { sortOrder: 'asc' } });

export const getJobs = () =>
  prisma.job.findMany({ where: { published: true }, orderBy: { sortOrder: 'asc' } });

export async function getSetting<T = unknown>(key: string): Promise<string | null> {
  const s = await prisma.setting.findUnique({ where: { key } });
  return s?.i18n ?? null;
}

export const getInquiries = () =>
  prisma.inquiry.findMany({ orderBy: { createdAt: 'desc' } });
