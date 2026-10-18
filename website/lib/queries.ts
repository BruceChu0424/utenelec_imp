import type { Prisma } from '@prisma/client';
import { cache } from 'react';
import {
  type CatalogFamilyRecord,
  type CatalogProduct,
  type ProductWithRelations,
  toCatalogProduct,
} from './catalog';
import { type ProductFunctionType } from './product-taxonomy';
import { catalogFacets, catalogWhere, catalogWindow, catalogTextFilter } from './catalog-query';
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
} satisfies Prisma.ProductFindManyArgs;

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

/** Navigation never loads product images, variants or descriptions. */
export const getCatalogNavigation = cache(async () => prisma.series.findMany({
  where: { published: true, OR: [{ catalogRole: 'FAMILY' }, { catalogRole: 'UNCLASSIFIED', parentId: null, OR: [{ products: { some: { published: true } } }, { children: { some: { published: true, products: { some: { published: true } } } } }] }] },
  orderBy: [{ sortOrder: 'asc' }, { id: 'asc' }],
  select: { id: true, code: true, publicSlug: true, i18n: true, updatedAt: true, children: { where: { published: true, OR: [{ catalogRole: 'COLLECTION' }, { catalogRole: 'UNCLASSIFIED' }] }, select: { id: true, code: true, publicSlug: true } } },
}));

export type CatalogFamilyResolution = {
  family: CatalogFamilyRecord;
  canonicalSlug: string;
  matchedCollectionId?: string;
};

const resolveCatalogIdentity = cache(async (identifier: string) => {
  const normalized = identifier.trim().toLocaleLowerCase();
  if (!normalized) return null;
  const identities = await getCatalogNavigation();
  for (const identity of identities) {
    const direct = [identity.code, identity.publicSlug].some(value => value?.toLocaleLowerCase() === normalized);
    const collection = identity.children.find(child => [child.code, child.publicSlug].some(value => value?.toLocaleLowerCase() === normalized));
    if (direct || collection) return { identity, canonicalSlug: identity.publicSlug || identity.code, matchedCollectionId: collection?.id };
  }
  return null;
});

/** Cover media is loaded only by pages that actually show a family cover. */
export const resolveCatalogFamily = cache(async (identifier: string): Promise<CatalogFamilyResolution | null> => {
  const resolution = await resolveCatalogIdentity(identifier);
  if (!resolution) return null;
  const family = await prisma.series.findUnique({ where: { id: resolution.identity.id }, include: {
    parent: true,
    media: { where: { published: true }, orderBy: [{ sortOrder: 'asc' }, { id: 'asc' }] },
    products: productPreviewSelection,
    children: { where: { published: true, OR: [{ catalogRole: 'COLLECTION' }, { catalogRole: 'UNCLASSIFIED' }] }, orderBy: [{ sortOrder: 'asc' }, { id: 'asc' }], include: { parent: true, products: productPreviewSelection, _count: { select: { products: { where: { published: true } } } } } },
    _count: { select: { products: { where: { published: true } } } },
  } });
  if (!family?.published) return null;
  return { family: family as unknown as CatalogFamilyRecord, canonicalSlug: resolution.canonicalSlug, matchedCollectionId: resolution.matchedCollectionId };
});

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
  const resolution = await resolveCatalogIdentity(input.familyIdentifier);
  if (!resolution) return null;
  const seriesIds = [resolution.identity.id, ...resolution.identity.children.map(child => child.id)];
  const where = catalogWhere(seriesIds, input);
  const window = catalogWindow(input.offset, input.take);
  const [records, total, groups] = await prisma.$transaction([
    prisma.product.findMany({
      where, ...window,
      orderBy: [{ sortOrder: 'asc' }, { createdAt: 'desc' }, { id: 'asc' }],
      include: { series: { include: { parent: true } }, variants: { where: { published: true }, orderBy: [{ isDefault: 'desc' }, { sortOrder: 'asc' }, { id: 'asc' }] } },
    }),
    prisma.product.count({ where }),
    prisma.product.groupBy({ by: ['functionType', 'gangCount'], orderBy: [{ functionType: 'asc' }, { gangCount: 'asc' }], where: catalogWhere(seriesIds, { query: input.query }), _count: { _all: true } }),
  ]);
  return {
    products: (records as unknown as ProductWithRelations[]).map(product => toCatalogProduct(product, input.locale, input.standardName)),
    total,
    canonicalSlug: resolution.canonicalSlug,
    facets: catalogFacets(groups as Array<{ functionType: string | null; gangCount: number | null; _count: { _all: number } }>),
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

/** Studio search is bounded at the database; a valid variant deep link is
 * pinned independently of the current page rather than silently substituted. */
export async function queryStudioProducts(input: { query?: string; offset?: number; variantId?: string } = {}) {
  // Explicit NULL branches are essential: SQL NOT over nullable source/slug
  // fields otherwise removes ordinary unclassified series from the preview.
  const wallSeries = { AND: [
    { OR: [{ publicSlug: null }, { publicSlug: { not: { contains: 'floor' } } }] },
    { code: { not: { contains: 'floor' } } },
    { OR: [{ sourceIdentity: null }, { sourceIdentity: { not: 'ch-uten-v2:series:53' } }] },
  ] };
  const base = publicProductWhere({ sceneEnabled: true, variants: { some: { published: true, image: { not: null } } }, series: { is: { AND: [wallSeries, { OR: [{ parentId: null }, { parent: { is: wallSeries } }] }] } } });
  const query = input.query?.normalize('NFKC').trim().slice(0, 80) || '';
  const where = query ? { AND: [base, { OR: [{ i18n: catalogTextFilter(query) }, { model: catalogTextFilter(query) }, { series: { is: { i18n: catalogTextFilter(query) } } }] }] } : base;
  const include = { series: { include: { parent: true } }, variants: { where: { published: true, image: { not: null } }, orderBy: [{ isDefault: 'desc' as const }, { sortOrder: 'asc' as const }, { id: 'asc' as const }] } };
  const [products, total] = await prisma.$transaction([
    prisma.product.findMany({ where, ...catalogWindow(input.offset, 24), orderBy: [{ sortOrder: 'asc' }, { createdAt: 'desc' }, { id: 'asc' }], include }),
    prisma.product.count({ where }),
  ]);
  const selected = input.variantId ? await prisma.product.findFirst({ where: { AND: [base, { variants: { some: { id: input.variantId, published: true, image: { not: null } } } }] }, include }) : null;
  return { products: selected && !products.some(product => product.id === selected.id) ? [selected, ...products] : products, total, selected };
}

/** Only published scene presets are visible in the public studio. */
export const getScenePresets = () =>
  prisma.scenePreset.findMany({
    where: { published: true },
    orderBy: [{ sortOrder: 'asc' }, { createdAt: 'asc' }],
  });

export const getNewsList = (take?: number, category?: string) =>
  prisma.news.findMany({
    where: publicNewsWhere(category ? { category } : {}),
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

/** Read-only context for the contact page; the action independently repeats
 * these publication checks when accepting an inquiry. */
export async function getPublicInquiryContext(input: { productId?: string; variantId?: string; seriesId?: string }, locale: string): Promise<{ context: { productId?: string; variantId?: string; seriesId?: string }; label: string } | null> {
  if (input.productId) {
    const product = await prisma.product.findFirst({ where: publicProductWhere({ id: input.productId }), include: { series: { include: { parent: true } }, variants: { where: { published: true } } } });
    if (!product || (input.seriesId && input.seriesId !== product.seriesId && input.seriesId !== product.series?.parentId)) return null;
    const variant = input.variantId ? product.variants.find(item => item.id === input.variantId) : undefined;
    if (input.variantId && !variant) return null;
    const view = toCatalogProduct(product as unknown as ProductWithRelations, locale);
    return { context: { productId: product.id, ...(variant ? { variantId: variant.id } : {}), ...(product.seriesId ? { seriesId: product.seriesId } : {}) }, label: [view.seriesName, view.name].filter(Boolean).join(' · ') };
  }
  if (input.variantId) return null;
  if (input.seriesId) {
    const families = await getCatalogNavigation();
    const family = families.find(item => item.id === input.seriesId || item.children.some(child => child.id === input.seriesId));
    if (!family) return null;
    const { tr } = await import('./content');
    return { context: { seriesId: input.seriesId }, label: tr<{ name?: string }>(family.i18n, locale).name || family.code };
  }
  return { context: {}, label: '' };
}
