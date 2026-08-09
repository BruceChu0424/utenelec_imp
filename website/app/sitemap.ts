import type { MetadataRoute } from 'next';
import { catalogFamilySlug } from '@/lib/catalog';
import { prisma } from '@/lib/db';
import { publicNewsWhere, publicProductWhere } from '@/lib/publication';
import { getCatalogFamilies } from '@/lib/queries';
import { directContentLocales, hasText, localizedUrl, REVIEWED_SITE_LOCALES } from '@/lib/seo';

export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
  const [products, families, news] = await Promise.all([
    prisma.product.findMany({
      where: publicProductWhere(),
      select: { slug: true, i18n: true, updatedAt: true, series: { include: { parent: true } } },
    }),
    getCatalogFamilies(),
    prisma.news.findMany({
      where: publicNewsWhere(),
      select: { slug: true, i18n: true, updatedAt: true },
    }),
  ]);

  const staticPaths = [
    '',
    '/products',
    '/studio',
    '/capabilities',
    '/partners',
    '/resources',
    '/about',
    '/cases',
    '/news',
    '/careers',
    '/contact',
    '/privacy',
  ];
  const staticEntries: MetadataRoute.Sitemap = REVIEWED_SITE_LOCALES.flatMap((locale) =>
    staticPaths.map((path) => ({
      url: localizedUrl(locale, path),
      changeFrequency: path === '' || path === '/products' ? 'weekly' : 'monthly',
      priority: path === '' ? 1 : path === '/products' || path === '/studio' ? 0.9 : 0.7,
    })),
  );

  const productEntries: MetadataRoute.Sitemap = products.flatMap((product) => {
    const familySlug = catalogFamilySlug(product.series as never);
    if (!familySlug) return [];
    const locales = directContentLocales<{ name?: string }>(product.i18n, (content) => hasText(content.name));
    return locales.map((locale) => ({
      url: localizedUrl(locale, `/products/${familySlug}/${product.slug}`),
      lastModified: product.updatedAt,
      changeFrequency: 'monthly' as const,
      priority: 0.8,
    }));
  });

  const seriesEntries: MetadataRoute.Sitemap = families.flatMap((item) => {
    const locales = directContentLocales<{ name?: string }>(item.i18n, (content) => hasText(content.name));
    const slug = item.publicSlug || item.code;
    return locales.map((locale) => ({
      url: localizedUrl(locale, `/products/${slug}`),
      lastModified: item.updatedAt,
      changeFrequency: 'monthly' as const,
      priority: 0.8,
    }));
  });

  const newsEntries: MetadataRoute.Sitemap = news.flatMap((item) => {
    const locales = directContentLocales<{ title?: string; content?: string }>(
      item.i18n,
      (content) => hasText(content.title) && hasText(content.content),
    );
    return locales.map((locale) => ({
      url: localizedUrl(locale, `/news/${item.slug}`),
      lastModified: item.updatedAt,
      changeFrequency: 'yearly' as const,
      priority: 0.6,
    }));
  });

  return [...staticEntries, ...seriesEntries, ...productEntries, ...newsEntries];
}
