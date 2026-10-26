import assert from 'node:assert/strict';
import test from 'node:test';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { ArticleContent } from '../components/content/ArticleContent';
import { isLegacyCompanyActivity } from '../lib/content';
import { migratedDatabase } from './helpers/migrated-database';
import { caseSlugForPathname, publicLocaleForPathname, PUBLIC_CASE_SLUG_HEADER, PUBLIC_ROUTE_LOCALE_HEADER } from '../lib/public-route-context';
import { routing } from '../i18n/routing';

test('early case context is derived only from an actual localized case path', async () => {
  assert.equal(caseSlugForPathname('/zh/cases/actual-case'), 'actual-case');
  assert.equal(caseSlugForPathname('/zh/cases/missing-case.html'), 'missing-case.html');
  assert.equal(caseSlugForPathname('/en/cases/encoded%20case'), 'encoded case');
  assert.equal(caseSlugForPathname('/zh/about'), null);
  assert.equal(caseSlugForPathname('/unknown/cases/actual-case'), null);
  assert.equal(caseSlugForPathname('/zh/cases/%zz'), '');
  assert.equal(publicLocaleForPathname('/ar/cases/missing-case'), 'ar');
  assert.equal(publicLocaleForPathname('/unknown/cases/missing-case'), 'en');
  const { proxy } = await import('../proxy');
  const { NextRequest } = await import('next/server');
  const unrelated = await proxy(new NextRequest('https://www.ch-uten.com/zh/about', { headers: { [PUBLIC_CASE_SLUG_HEADER]: 'forged' } }));
  assert.equal(unrelated.headers.get(`x-middleware-request-${PUBLIC_CASE_SLUG_HEADER}`), null);
  const actual = await proxy(new NextRequest('https://www.ch-uten.com/zh/about', { headers: { [PUBLIC_CASE_SLUG_HEADER]: 'forged', [PUBLIC_ROUTE_LOCALE_HEADER]: 'fr' } }));
  assert.equal(actual.headers.get(`x-middleware-request-${PUBLIC_CASE_SLUG_HEADER}`), null);
  assert.equal(actual.headers.get('x-middleware-request-x-next-intl-locale'), 'zh');
  assert.equal(actual.headers.get(`x-middleware-request-${PUBLIC_ROUTE_LOCALE_HEADER}`), 'zh');
  const login = await proxy(new NextRequest('https://www.ch-uten.com/admin/login', { headers: { [PUBLIC_CASE_SLUG_HEADER]: 'forged' } }));
  assert.equal(login.headers.get(`x-middleware-request-${PUBLIC_CASE_SLUG_HEADER}`), null);
});

test('the locale router keeps a truly unmatched root for the branded global 404 document', () => {
  const rootPages: string[] = [];
  const inspectRoot = (directory: string) => {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      if (entry.isFile() && /^page\.(?:tsx?|jsx?|mdx)$/u.test(entry.name)) rootPages.push(path.join(directory, entry.name));
      else if (entry.isDirectory() && (/^\([^)]*\)$/u.test(entry.name) || entry.name.startsWith('@')))
        inspectRoot(path.join(directory, entry.name));
    }
  };
  inspectRoot(fileURLToPath(new URL('../app', import.meta.url)));
  assert.deepEqual(rootPages, [], 'The branded 404 rewrite requires no direct or grouped app root page');
  const config = readFileSync(new URL('../next.config.mjs', import.meta.url), 'utf8');
  assert.match(config, /globalNotFound:\s*true/u);
  assert.match(config, /skipProxyUrlNormalize:\s*true/u);
  const proxySource = readFileSync(new URL('../proxy.ts', import.meta.url), 'utf8');
  assert.ok(proxySource.includes(`/:locale(${routing.locales.join('|')})/:path*`));
  const globalPage = readFileSync(new URL('../app/global-not-found.tsx', import.meta.url), 'utf8');
  assert.match(globalPage, /<html lang=\{locale\}/u);
  assert.match(globalPage, /<body className="public-site/u);
  assert.match(globalPage, /<PublicNotFound\s*\/>/u);
  assert.doesNotMatch(globalPage, /dangerouslySetInnerHTML/u);
});

test('shared article rendering preserves complete case and news content as escaped text', () => {
  const completeText = `## Archive context\n\n${'Historical text. '.repeat(45)}END_OF_PUBLIC_HISTORY\n\n- Confirm scope\n- <script>alert("case")</script>`;
  const html = renderToStaticMarkup(createElement(ArticleContent, { text: completeText, emptyLabel: 'No content' }));
  assert.match(html, /<h2[^>]*>Archive context<\/h2>/u);
  assert.match(html, /END_OF_PUBLIC_HISTORY/u);
  assert.match(html, /<ul/u);
  assert.match(html, /&lt;script&gt;/u);
  assert.doesNotMatch(html, /<script/u);
  assert.equal(isLegacyCompanyActivity('quanzhou-dealer-conference'), true);
  assert.equal(isLegacyCompanyActivity('rongqiao-jincheng-project'), true);
  assert.equal(isLegacyCompanyActivity('new-confirmed-case'), false);
});

test('case list, detail metadata and sitemap retain one live publication authority', async (t) => {
  const fixture = await migratedDatabase();
  const previousUrl = process.env.DATABASE_URL;
  const previousSiteUrl = process.env.SITE_URL;
  process.env.DATABASE_URL = fixture.databaseUrl;
  process.env.SITE_URL = 'https://www.ch-uten.com';
  const { prisma } = await import('../lib/db');
  try {
    await prisma.caseItem.create({ data: { id: 'public-case', slug: 'public-case', published: true,
      i18n: JSON.stringify({ zh: { title: '项目资料', content: '完整项目正文' }, en: { title: 'Project information', content: 'Complete project text' } }) } });
    await prisma.caseItem.create({ data: { id: 'archive-case', slug: 'quanzhou-dealer-conference', published: true,
      i18n: JSON.stringify({ zh: { title: '历史活动', content: '历史记录，不代表现行项目交付。' } }) } });
    await prisma.caseItem.create({ data: { id: 'draft-case', slug: 'draft-case', published: false,
      i18n: JSON.stringify({ zh: { title: '草稿', content: '不公开正文' } }) } });
    const { getCases, getCaseBySlug } = await import('../lib/queries');
    const { generateMetadata } = await import('../app/[locale]/cases/[slug]/page');
    const { default: sitemap } = await import('../app/sitemap');
    const { proxy } = await import('../proxy');
    const { NextRequest } = await import('next/server');

    await t.test('unknown and draft details cannot be read through the public query', async () => {
      assert.deepEqual((await getCases()).map(item => item.id).sort(), ['archive-case', 'public-case']);
      assert.equal(await getCaseBySlug('draft-case'), null);
      assert.equal(await getCaseBySlug('missing-case'), null);
      assert.equal((await getCaseBySlug('public-case'))?.id, 'public-case');
      await assert.rejects(generateMetadata({ params: Promise.resolve({ locale: 'zh', slug: 'draft-case' }) }), /NEXT_HTTP_ERROR_FALLBACK;404/u);
      for (const slug of ['draft-case', 'missing-case']) {
        const early = await proxy(new NextRequest(`https://www.ch-uten.com/zh/cases/${slug}`, {
          headers: { [PUBLIC_CASE_SLUG_HEADER]: 'public-case', [PUBLIC_ROUTE_LOCALE_HEADER]: 'fr' },
        }));
        assert.equal(new URL(early.headers.get('x-middleware-rewrite')!).pathname, '/');
        assert.equal(early.headers.get(`x-middleware-request-${PUBLIC_ROUTE_LOCALE_HEADER}`), 'zh');
        assert.equal(early.headers.get(`x-middleware-request-${PUBLIC_CASE_SLUG_HEADER}`), null);
      }
      const visible = await proxy(new NextRequest('https://www.ch-uten.com/zh/cases/public-case'));
      assert.equal(visible.headers.get('x-middleware-next'), '1');
    });

    await t.test('direct content determines canonical, hreflang and noindex instead of inventing a translation', async () => {
      const direct = await generateMetadata({ params: Promise.resolve({ locale: 'en', slug: 'public-case' }) });
      assert.equal(direct.alternates?.canonical, 'https://www.ch-uten.com/en/cases/public-case');
      assert.deepEqual(Object.keys(direct.alternates?.languages || {}).sort(), ['en', 'x-default', 'zh']);
      assert.deepEqual(direct.robots, { index: true, follow: true });
      const fallback = await generateMetadata({ params: Promise.resolve({ locale: 'fr', slug: 'quanzhou-dealer-conference' }) });
      assert.deepEqual(fallback.robots, { index: false, follow: true });
      assert.equal(fallback.alternates?.canonical, 'https://www.ch-uten.com/zh/cases/quanzhou-dealer-conference');
      assert.deepEqual(Object.keys(fallback.alternates?.languages || {}).sort(), ['x-default', 'zh']);
    });

    await t.test('published detail routes are discoverable and vanish from all readers after unpublishing', async () => {
      const before = (await sitemap()).map(entry => entry.url);
      assert.ok(before.includes('https://www.ch-uten.com/en/cases/public-case'));
      assert.ok(before.includes('https://www.ch-uten.com/zh/cases/quanzhou-dealer-conference'));
      assert.equal(before.some(url => url.includes('draft-case')), false);
      await prisma.caseItem.update({ where: { id: 'public-case' }, data: { published: false } });
      assert.equal(await getCaseBySlug('public-case'), null);
      assert.equal((await getCases()).some(item => item.id === 'public-case'), false);
      assert.equal((await sitemap()).some(entry => entry.url.includes('/cases/public-case')), false);
    });
  } finally {
    await prisma.$disconnect();
    if (previousUrl === undefined) delete process.env.DATABASE_URL; else process.env.DATABASE_URL = previousUrl;
    if (previousSiteUrl === undefined) delete process.env.SITE_URL; else process.env.SITE_URL = previousSiteUrl;
    await fixture.dispose();
  }
});
