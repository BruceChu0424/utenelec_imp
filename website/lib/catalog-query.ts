import type { Prisma } from '@prisma/client';
import { PRODUCT_FUNCTION_TYPES, isProductFunctionType, type ProductFunctionType } from './product-taxonomy';
import { publicProductWhere } from './publication';

export const CATALOG_PAGE_SIZE = 24;

export type CatalogFilters = { query?: string; functionType?: ProductFunctionType | null; gangCount?: number | null };

export function catalogWindow(offset = 0, take = CATALOG_PAGE_SIZE) {
  return {
    skip: Number.isFinite(offset) ? Math.max(0, Math.min(100_000, Math.floor(offset))) : 0,
    take: Number.isFinite(take) ? Math.max(1, Math.min(48, Math.floor(take))) : CATALOG_PAGE_SIZE,
  };
}

/** Persisted classifications are the filter authority. Unclassified records
 * remain available in Other and text search; names never become SKU facts. */
export function catalogWhere(seriesIds: string[], filters: CatalogFilters = {}): Prisma.ProductWhereInput {
  const conditions: Prisma.ProductWhereInput[] = [{ seriesId: { in: seriesIds } }];
  if (filters.functionType === 'other') {
    conditions.push({ OR: [{ functionType: null }, { functionType: { notIn: PRODUCT_FUNCTION_TYPES.filter(x => x !== 'other') } }] });
  } else if (isProductFunctionType(filters.functionType)) conditions.push({ functionType: filters.functionType });
  if (Number.isInteger(filters.gangCount) && filters.gangCount! > 0) conditions.push({ gangCount: filters.gangCount });
  return publicProductWhere({ AND: conditions });
}

export function catalogFacets(groups: Array<{ functionType: string | null; gangCount: number | null; _count: { _all: number } }>) {
  const functions = new Map<ProductFunctionType, number>();
  const gangs = new Map<number, number>();
  for (const row of groups) {
    const key = isProductFunctionType(row.functionType) ? row.functionType : 'other';
    functions.set(key, (functions.get(key) || 0) + row._count._all);
    if (row.gangCount && row.gangCount > 0) gangs.set(row.gangCount, (gangs.get(row.gangCount) || 0) + row._count._all);
  }
  return {
    functions: PRODUCT_FUNCTION_TYPES.filter(value => functions.has(value)).map(value => ({ value, count: functions.get(value)! })),
    gangs: [...gangs].sort(([a], [b]) => a - b).map(([value, count]) => ({ value, count })),
  };
}
