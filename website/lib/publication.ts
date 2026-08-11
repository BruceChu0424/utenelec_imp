import type { Prisma } from '@prisma/client';

export type CatalogPublicationSeries = {
  catalogRole: string;
  published: boolean;
  parent?: {
    catalogRole: string;
    published: boolean;
  } | null;
};

export type SeriesPublicationIssue =
  | 'collection-parent-required'
  | 'published-collections-require-family'
  | 'published-products-require-public-series';

export type SeriesPublicationDependents = {
  publishedProducts: number;
  publishedCollections: number;
};

/**
 * Draft series may be incomplete, but a published COLLECTION must resolve to
 * an active top-level FAMILY or its products would be marked as published in
 * the CMS while remaining unreachable from the public catalog.
 */
export function getSeriesPublicationIssue(
  published: boolean,
  catalogRole: string,
  parent: CatalogPublicationSeries['parent'],
  dependents: SeriesPublicationDependents = { publishedProducts: 0, publishedCollections: 0 },
): SeriesPublicationIssue | null {
  const publishedCollection = published && catalogRole === 'COLLECTION';
  const validCollectionParent = parent?.published && parent.catalogRole === 'FAMILY';
  if (publishedCollection && !validCollectionParent) return 'collection-parent-required';

  if (dependents.publishedCollections > 0 && !(published && catalogRole === 'FAMILY')) {
    return 'published-collections-require-family';
  }

  const publiclyVisibleSeries = published && (
    catalogRole === 'FAMILY' || (catalogRole === 'COLLECTION' && validCollectionParent)
  );
  if (dependents.publishedProducts > 0 && !publiclyVisibleSeries) {
    return 'published-products-require-public-series';
  }
  return null;
}

export type ProductPublicationIssue =
  | 'series-required'
  | 'series-unpublished'
  | 'collection-parent-required'
  | 'series-role-not-public';

/** Keep new CMS publications within the canonical public FAMILY hierarchy. */
export function getProductPublicationIssue(
  published: boolean,
  series: CatalogPublicationSeries | null,
): ProductPublicationIssue | null {
  if (!published) return null;
  if (!series) return 'series-required';
  if (!series.published) return 'series-unpublished';
  if (series.catalogRole === 'FAMILY') return null;
  if (series.catalogRole === 'COLLECTION') {
    return series.parent?.published && series.parent.catalogRole === 'FAMILY'
      ? null
      : 'collection-parent-required';
  }
  return 'series-role-not-public';
}

/**
 * Public catalog records must be published and belong to an active catalog
 * family. A published COLLECTION cannot keep leaking products after its FAMILY
 * is taken offline. The UNCLASSIFIED branches are a narrow compatibility path
 * for the legacy import before its one-time family classification is reviewed;
 * once a parent is marked FAMILY, its own published flag is authoritative.
 */
export function publicProductWhere(extra: Prisma.ProductWhereInput = {}): Prisma.ProductWhereInput {
  return {
    AND: [
      {
        published: true,
        series: {
          is: {
            published: true,
            OR: [
              { catalogRole: 'FAMILY' },
              { catalogRole: 'UNCLASSIFIED', parentId: null },
              { parent: { is: { published: true, catalogRole: 'FAMILY' } } },
              {
                catalogRole: 'UNCLASSIFIED',
                parent: { is: { published: true, catalogRole: 'UNCLASSIFIED' } },
              },
            ],
          },
        },
      } as unknown as Prisma.ProductWhereInput,
      extra,
    ],
  };
}

/** Public news records must always be explicitly published. */
export function publicNewsWhere(extra: Prisma.NewsWhereInput = {}): Prisma.NewsWhereInput {
  return { AND: [{ published: true }, extra] };
}
