import createNextIntlPlugin from 'next-intl/plugin';

const withNextIntl = createNextIntlPlugin('./i18n/request.ts');

const publicLocales = ['zh', 'en', 'es', 'fr', 'de', 'pt', 'ar', 'ru', 'ja', 'ko'];
const safeCatalogSegment = /^[a-z0-9][a-z0-9-]*$/;

let catalogRedirectsPromise;

async function loadCatalogRedirects() {
  if (catalogRedirectsPromise) return catalogRedirectsPromise;

  catalogRedirectsPromise = (async () => {
    const { PrismaClient } = await import('@prisma/client');
    const prisma = new PrismaClient();

    try {
      const series = await prisma.series.findMany({
        where: { published: true },
        select: {
          code: true,
          publicSlug: true,
          catalogRole: true,
          parent: {
            select: {
              publicSlug: true,
              code: true,
              catalogRole: true,
              published: true,
            },
          },
        },
      });
      const localePattern = publicLocales.join('|');
      const seen = new Set();
      const redirects = [];

      for (const item of series) {
        const family = item.catalogRole === 'FAMILY'
          ? item
          : item.catalogRole === 'COLLECTION' && item.parent?.catalogRole === 'FAMILY' && item.parent.published
            ? item.parent
            : null;
        const canonical = family?.publicSlug || family?.code;
        const alias = item.code;
        if (!canonical || alias === canonical || !safeCatalogSegment.test(alias) || !safeCatalogSegment.test(canonical)) continue;

        const key = `${alias}:${canonical}`;
        if (seen.has(key)) continue;
        seen.add(key);
        redirects.push(
          {
            source: `/:locale(${localePattern})/products/${alias}`,
            destination: `/:locale/products/${canonical}`,
            permanent: true,
          },
          {
            source: `/:locale(${localePattern})/products/${alias}/:slug`,
            destination: `/:locale/products/${canonical}/:slug`,
            permanent: true,
          },
        );
      }

      return redirects;
    } finally {
      await prisma.$disconnect();
    }
  })();

  return catalogRedirectsPromise;
}

const securityHeaders = [
  { key: 'X-Content-Type-Options', value: 'nosniff' },
  { key: 'X-Frame-Options', value: 'SAMEORIGIN' },
  { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
  { key: 'Permissions-Policy', value: 'camera=(), microphone=(), geolocation=()' },
];

// Browsers only honor HSTS over HTTPS. The deployment edge must still redirect
// every HTTP request to HTTPS before the site is made public.
if (process.env.NODE_ENV === 'production') {
  securityHeaders.push({ key: 'Strict-Transport-Security', value: 'max-age=31536000' });
}

/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  poweredByHeader: false,
  output: 'standalone',
  // CMS media is intentionally outside immutable releases and is served by
  // Nginx from the durable uploads mount.  The Next image optimizer resolves
  // relative URLs inside Node, where that Nginx-only path does not exist.
  // Emit direct browser URLs so newly committed media is readable immediately
  // without copying mutable files into a release.
  images: { unoptimized: true },
  // Runtime state is mounted separately from immutable releases. Keep local
  // SQLite files out of traced dependencies. Next still copies `public/` into
  // its raw standalone output, so deploy/assemble-release.mjs is mandatory.
  outputFileTracingExcludes: {
    '/*': [
      './prisma/**/*.db',
      './prisma/**/*.db-*',
      './prisma/**/*.sqlite',
      './prisma/**/*.sqlite-*',
      './prisma/**/*.sqlite3',
      './prisma/**/*.sqlite3-*',
      './public/uploads/**/*',
    ],
  },
  experimental: {
    serverActions: { bodySizeLimit: '10mb' },
  },
  async headers() {
    return [{
      source: '/(.*)',
      headers: securityHeaders,
    }];
  },
  // Redirect legacy catalogue aliases before React starts streaming. A
  // Server Component redirect can otherwise degrade to `200 + meta refresh`,
  // which is slower for visitors and ambiguous to search engines.
  async redirects() {
    return loadCatalogRedirects();
  },
};

export default withNextIntl(nextConfig);
