import { prisma } from './db';
import { publicProductWhere, publicSeriesWhere } from './publication';
import { pick } from './content';

export function publicResourceWhere() {
  return { published: true, AND: [
    { OR: [{ productId: null }, { product: { is: publicProductWhere() } }] },
    { OR: [{ seriesId: null }, { series: { is: publicSeriesWhere() } }] },
  ] };
}
export async function getPublicResources(locale: string, productId?: string) {
  const records = await prisma.resourceDocument.findMany({ where: {
    ...publicResourceWhere(), language: { in: [...new Set([locale, 'en', 'zh'])] },
    ...(productId ? { productId } : {}),
  }, orderBy: [{ updatedAt: 'desc' }, { id: 'asc' }], take: 100,
    include: { asset: { select: { sizeBytes: true, mimeType: true } } } });
  return records.map(r => ({ id: r.id, title: pick<{ title?: string }>(r.i18n, locale)?.title || r.slug,
    description: pick<{ description?: string }>(r.i18n, locale)?.description || '',
    language: r.language, version: r.version, market: r.market, sizeBytes: r.asset.sizeBytes,
    href: `/api/resources/${r.id}/download`, updatedAt: r.updatedAt.toISOString() }));
}
