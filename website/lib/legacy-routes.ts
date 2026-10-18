import type { PrismaClient } from '@prisma/client';
import { prisma } from './db';
import { publicNewsWhere, publicProductWhere } from './publication';

// Verified against .scrape/seed/extracted.json order used by prisma/seed.ts,
// then matched to the frozen v2 source IDs. In particular ID 18 is news-6,
// not news-18. English IDs 14/15 have no imported public News row and stay 404.
export const LEGACY_NEWS_SLUGS: Readonly<Record<string, { slug: string; locales: readonly string[] }>> = {
  '1': { slug: 'news-0', locales: ['zh'] }, '10': { slug: 'news-1', locales: ['zh'] },
  '11': { slug: 'news-2', locales: ['zh'] }, '13': { slug: 'news-3', locales: ['zh'] },
  '16': { slug: 'news-4', locales: ['zh'] }, '17': { slug: 'news-5', locales: ['zh'] },
  '18': { slug: 'news-6', locales: ['zh'] }, '19': { slug: 'news-7', locales: ['zh'] },
  '2': { slug: 'news-8', locales: ['zh'] }, '20': { slug: 'news-9', locales: ['zh'] },
  '21': { slug: 'news-10', locales: ['zh'] }, '22': { slug: 'news-11', locales: ['zh'] },
  '23': { slug: 'news-12', locales: ['zh'] }, '24': { slug: 'news-13', locales: ['zh', 'en'] },
  '3': { slug: 'news-14', locales: ['zh'] }, '4': { slug: 'news-15', locales: ['zh'] },
  '5': { slug: 'news-16', locales: ['zh'] }, '8': { slug: 'news-17', locales: ['zh'] },
  '9': { slug: 'news-18', locales: ['zh'] },
};

/** undefined means absent, null means invalid/ambiguous. */
function numericParameter(search: URLSearchParams, name: string): string | null | undefined {
  const values = [...search.entries()].filter(([key]) => key.toLowerCase() === name.toLowerCase()).map(([, value]) => value);
  if (!values.length) return undefined;
  if (values.length !== 1 || !/^[0-9]{1,12}$/.test(values[0])) return null;
  const value = values[0].replace(/^0+(?=\d)/, '');
  return value === '0' ? null : value;
}
type LegacyDb = Pick<PrismaClient, 'product' | 'series' | 'news' | 'job'>;
type SeriesIdentity = { published: boolean; catalogRole: string; code: string; publicSlug: string | null; parentId?: string | null };
const segment = (value: string) => /^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(value) ? encodeURIComponent(value) : null;

/** Runtime resolution deliberately avoids a build-time redirect cache: an
 * unpublished product, family or article stops resolving immediately. */
export async function resolveLegacyDestination(locale: string, file: string, search: URLSearchParams, db: LegacyDb = prisma): Promise<string | null> {
  if (locale !== 'zh' && locale !== 'en') return null;
  const page = file.toLowerCase();
  const id = numericParameter(search, 'id');
  const sort = numericParameter(search, 'sortid');
  if (id === null || sort === null) return null;
  if (['product.asp', 'news.asp', 'honor.asp', 'faq.asp'].includes(page) && id !== undefined) return null;
  if (!['product.asp', 'productshow.asp', 'news.asp', 'newsshow.asp', 'honor.asp', 'faq.asp'].includes(page) && sort !== undefined) return null;
  const prefix = `/${locale}`;
  if (page === 'productshow.asp') {
    if (!id) return null;
    const product = await db.product.findFirst({ where: publicProductWhere({ sourceIdentity: `ch-uten-v2:product:${id}`, legacyRecords: { some: { sourceSystem: 'ch-uten-v2', entityType: 'product', sourceId: id, locale } } }), include: { series: { include: { parent: true } } } });
    if (!product?.series) return null;
    const family = product.series.catalogRole === 'FAMILY' || !product.series.parent ? product.series : product.series.parent;
    const familySlug = segment(family.publicSlug || family.code), productSlug = segment(product.slug);
    return familySlug && productSlug ? `${prefix}/products/${familySlug}/${productSlug}` : null;
  }
  if (page === 'product.asp') {
    if (sort === undefined) return `${prefix}/products`;
    const record = await db.series.findFirst({ where: { published: true, sourceIdentity: `ch-uten-v2:series:${sort}`, legacyRecords: { some: { sourceSystem: 'ch-uten-v2', entityType: 'series', sourceId: sort, locale } } }, include: { parent: true, children: { where: { published: true, catalogRole: 'FAMILY' }, select: { published: true, catalogRole: true, code: true, publicSlug: true } } } });
    if (!record) return null;
    let family: SeriesIdentity | undefined;
    if (record.catalogRole === 'FAMILY' || (record.catalogRole === 'UNCLASSIFIED' && !record.parentId)) family = record;
    else if (['COLLECTION', 'UNCLASSIFIED'].includes(record.catalogRole) && record.parent?.published && ['FAMILY', 'UNCLASSIFIED'].includes(record.parent.catalogRole)) family = record.parent;
    else if (record.catalogRole === 'CONTAINER' && record.children.length === 1) family = record.children[0];
    const slug = family && segment(family.publicSlug || family.code);
    return slug ? `${prefix}/products/${slug}` : null;
  }
  if (page === 'newsshow.asp') {
    const mapping = id && LEGACY_NEWS_SLUGS[id];
    if (!mapping || !mapping.locales.includes(locale)) return null;
    const news = await db.news.findFirst({ where: publicNewsWhere({ slug: mapping.slug }), select: { slug: true } });
    return news ? `${prefix}/news/${encodeURIComponent(news.slug)}` : null;
  }
  if (page === 'jobshow.asp') {
    if (locale !== 'zh' || id !== '1') return null;
    const job = await db.job.findFirst({ where: { slug: 'regional-sales-manager', published: true }, select: { slug: true } });
    return job ? `${prefix}/careers#job-${encodeURIComponent(job.slug)}` : null;
  }
  if (page === 'news.asp') return sort === undefined ? `${prefix}/news` : sort === '1' ? `${prefix}/news?category=company` : sort === '2' ? `${prefix}/news?category=industry` : null;
  if (page === 'index.asp' && id === undefined && sort === undefined) return prefix;
  if (page === 'about.asp' && (id === undefined || (locale === 'en' ? ['1', '2'] : ['1', '2', '3', '4']).includes(id))) return `${prefix}/about`;
  if (page === 'contact.asp' && (id === undefined || id === '11')) return `${prefix}/contact`;
  if (page === 'feedback.asp' && id === undefined) return `${prefix}/contact`;
  if (locale === 'zh') {
    if (page === 'case.asp' && (id === undefined || id === '6')) return `${prefix}/cases`;
    if (page === 'join.asp' && (id === undefined || ['7', '8', '9'].includes(id))) return `${prefix}/partners`;
    if (page === 'tian.asp' && id === undefined) return `${prefix}/partners#project-brief`;
    if (page === 'job.asp' && id === undefined) return `${prefix}/careers`;
    if (page === 'ln.asp' && (id === undefined || id === '10')) return `${prefix}/careers`;
    if (page === 'honor.asp' && (sort === undefined || sort === '1')) return `${prefix}/capabilities`;
  } else {
    if (page === 'faq.asp' && (sort === undefined || sort === '4')) return `${prefix}/resources#faq`;
    if (page === 'service.asp' && (id === undefined || id === '5')) return `${prefix}/resources`;
  }
  return null;
}
