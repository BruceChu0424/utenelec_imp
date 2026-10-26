import type { Prisma } from '@prisma/client';
import { prisma } from './db';
import { publicProductWhere, publicSeriesWhere } from './publication';
import { pick } from './content';

export function publicResourceWhere() {
  return { published: true, AND: [
    { OR: [{ productId: null }, { product: { is: publicProductWhere() } }] },
    { OR: [{ seriesId: null }, { series: { is: publicSeriesWhere() } }] },
  ] };
}
export const PUBLIC_RESOURCE_PAGE_SIZE = 24;

/** One public query for the document library and applicable product documents.
 * Product-specific documents never become series-wide or general documents.
 * Count and rows share a read snapshot, including the product's public ancestry. */
export async function queryPublicResources(locale: string, options: { productId?: string; page?: number } = {}) {
  return prisma.$transaction(async (tx) => {
    let scope: Prisma.ResourceDocumentWhereInput = {};
    if (options.productId) {
      const product = await tx.product.findFirst({
        where: publicProductWhere({ id: options.productId }),
        select: { id: true, seriesId: true, series: { select: { parentId: true } } },
      });
      if (!product) return { items: [], total: 0, page: 1, pages: 1 };
      const seriesIds = [product.seriesId, product.series?.parentId].filter((id): id is string => Boolean(id));
      scope = { OR: [
        { productId: product.id },
        { productId: null, seriesId: { in: seriesIds } },
        { productId: null, seriesId: null },
      ] };
    }
    const where: Prisma.ResourceDocumentWhereInput = { AND: [
      publicResourceWhere(),
      { language: { in: [...new Set([locale, 'en', 'zh'])] } },
      scope,
    ] };
    const total = await tx.resourceDocument.count({ where });
    const pages = Math.max(1, Math.ceil(total / PUBLIC_RESOURCE_PAGE_SIZE));
    const requestedPage = typeof options.page === 'number' && Number.isFinite(options.page) ? Math.floor(options.page) : 1;
    const page = Math.max(1, Math.min(pages, requestedPage));
    const records = await tx.resourceDocument.findMany({ where,
      orderBy: [{ updatedAt: 'desc' }, { id: 'asc' }], skip: (page - 1) * PUBLIC_RESOURCE_PAGE_SIZE,
      take: PUBLIC_RESOURCE_PAGE_SIZE, include: { asset: { select: { sizeBytes: true } } },
    });
    return { total, page, pages, items: records.map(r => ({
      id: r.id, title: pick<{ title?: string }>(r.i18n, locale)?.title || r.slug,
      description: pick<{ description?: string }>(r.i18n, locale)?.description || '',
      language: r.language, version: r.version, market: r.market, sizeBytes: r.asset.sizeBytes,
      href: `/api/resources/${r.id}/download`, updatedAt: r.updatedAt.toISOString(),
    })) };
  }, { isolationLevel: 'Serializable' });
}

export function resourcePageHref(baseHref: string, page: number) {
  const url = new URL(baseHref, 'https://website.invalid');
  if (page > 1) url.searchParams.set('documentsPage', String(page));
  else url.searchParams.delete('documentsPage');
  return `${url.pathname}${url.search}#documents`;
}
