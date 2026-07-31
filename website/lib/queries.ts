import { prisma } from './db';

export const getSeries = () =>
  prisma.series.findMany({
    where: { published: true },
    orderBy: { sortOrder: 'asc' },
    include: { _count: { select: { products: true } } },
  });

export const getSeriesByCode = (code: string) =>
  prisma.series.findUnique({ where: { code }, include: { products: { where: { published: true }, orderBy: { sortOrder: 'asc' } } } });

export const getProducts = (opts: { seriesId?: string; take?: number; featured?: boolean } = {}) =>
  prisma.product.findMany({
    where: { published: true, ...(opts.seriesId ? { seriesId: opts.seriesId } : {}), ...(opts.featured ? { featured: true } : {}) },
    orderBy: [{ sortOrder: 'asc' }, { createdAt: 'desc' }],
    ...(opts.take ? { take: opts.take } : {}),
    include: { series: true },
  });

export const getProductBySlug = (slug: string) =>
  prisma.product.findUnique({ where: { slug }, include: { series: true } });

/// 最新产品 (首页精选展示, 苹果风少量大卡)
export const getLatestProducts = (take = 4) =>
  prisma.product.findMany({
    where: { published: true, image: { not: null } },
    orderBy: { createdAt: 'desc' },
    take,
    include: { series: true },
  });

export const getNewsList = (take?: number) =>
  prisma.news.findMany({
    where: { published: true },
    orderBy: { publishedAt: 'desc' },
    ...(take ? { take } : {}),
  });

export const getNewsBySlug = (slug: string) => prisma.news.findUnique({ where: { slug } });

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
