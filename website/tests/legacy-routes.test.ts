import assert from 'node:assert/strict';
import test from 'node:test';
import { PrismaClient } from '@prisma/client';
import { migratedDatabase } from './helpers/migrated-database';
import { resolveLegacyDestination, LEGACY_NEWS_SLUGS } from '../lib/legacy-routes';
import { publicProductWhere, publicSeriesWhere } from '../lib/publication';

test('legacy URLs retain source identity, language and current publication boundaries', async () => {
  const fixture = await migratedDatabase();
  const db = new PrismaClient({ datasources: { db: { url: fixture.databaseUrl } } });
  const resolve = (file: string, query = '', locale = 'zh') => resolveLegacyDestination(locale, file, new URLSearchParams(query), db);
  try {
    await db.series.create({ data: { id: 'family', code: 'legacy-v2-80', publicSlug: 's300', sourceIdentity: 'ch-uten-v2:series:80', catalogRole: 'FAMILY', published: true, i18n: '{}' } });
    await db.series.create({ data: { id: 'collection', parentId: 'family', code: 'legacy-v2-8', sourceIdentity: 'ch-uten-v2:series:8', catalogRole: 'COLLECTION', published: true, i18n: '{}' } });
    await db.series.create({ data: { id: 'archive', parentId: 'family', code: 'archived-child', sourceIdentity: 'ch-uten-v2:series:99', catalogRole: 'ARCHIVE', published: true, i18n: '{}' } });
    await db.series.create({ data: { id: 'container', parentId: 'family', code: 'container-child', catalogRole: 'CONTAINER', published: true, i18n: '{}' } });
    for (const [id, source, seriesId, published] of [['product', '607', 'collection', true], ['draft', '608', 'collection', false], ['archived-product', '609', 'archive', true], ['container-product', '610', 'container', true]] as const) {
      await db.product.create({ data: { id, slug: `legacy-v2-${source}`, sourceIdentity: `ch-uten-v2:product:${source}`, seriesId, published, i18n: '{"zh":{"name":"K11"},"en":{"name":"K11"}}' } });
    }
    await db.legacyImportRun.create({ data: { id: 'source-run', sourceSystem: 'ch-uten-v2', schemaVersion: 'fixture', catalogSha256: 'a', mediaSha256: 'b', qaReportSha256: 'c', checkpointSha256: 'd', bundleSha256: 'e', qaStatus: 'PASS', expectFull: true, inputRoot: 'fixture', backupPath: 'fixture', stats: '{}' } });
    for (const [entityType, sourceId, binding] of [
      ['product', '607', { productId: 'product' }], ['product', '608', { productId: 'draft' }], ['product', '609', { productId: 'archived-product' }], ['product', '610', { productId: 'container-product' }],
      ['series', '80', { seriesId: 'family' }], ['series', '8', { seriesId: 'collection' }], ['series', '99', { seriesId: 'archive' }],
    ] as const) for (const locale of ['zh', 'en']) await db.legacySourceRecord.create({ data: { importRunId: 'source-run', sourceSystem: 'ch-uten-v2', entityType, sourceId, locale, identityKey: `${entityType}:${sourceId}:${locale}`, sourceUrl: 'http://www.ch-uten.com/fixture', sourceHash: 'f', rawPayload: '{}', ...binding } });
    await db.news.create({ data: { slug: 'news-6', published: true, i18n: '{"zh":{"title":"Laboratory visit"}}' } });
    await db.news.create({ data: { slug: 'news-13', published: true, i18n: '{"en":{"title":"Invitation"}}' } });
    assert.equal(await resolve('productshow.asp', 'ID=607&SortID=8'), '/zh/products/s300/legacy-v2-607');
    assert.equal(await resolve('ProductShow.asp', 'id=607', 'en'), '/en/products/s300/legacy-v2-607');
    assert.equal(await resolve('Product.asp', 'SortID=8'), '/zh/products/s300');
    assert.equal(await resolve('product.asp', 'Sortid=80', 'en'), '/en/products/s300');
    assert.equal(await resolve('product.asp'), '/zh/products');
    await db.product.update({ where: { id: 'product' }, data: { i18n: '{"zh":{"name":"K11"}}' } });
    assert.equal(await resolve('productshow.asp', 'ID=607', 'en'), '/en/products/s300/legacy-v2-607');
    assert.equal(await resolve('productshow.asp', 'ID=608'), null);
    assert.equal(await resolve('productshow.asp', 'ID=609'), null);
    assert.equal(await resolve('productshow.asp', 'ID=610'), null);
    assert.equal(await resolve('Product.asp', 'SortID=99'), null);
    assert.equal(await db.product.count({ where: publicProductWhere() }), 1);
    assert.equal(await db.series.count({ where: publicSeriesWhere({ id: { in: ['archive', 'container'] } }) }), 0);
    assert.equal(await resolve('productshow.asp', 'ID=999999'), null);
    assert.equal(await resolve('productshow.asp', 'ID=607&id=608'), null);
    assert.equal(await resolve('productshow.asp', 'ID=../607'), null);
    assert.equal(await resolve('productshow.asp', 'ID=607', 'fr'), null);
    assert.equal(LEGACY_NEWS_SLUGS['18'].slug, 'news-6');
    assert.equal(await resolve('newsshow.asp', 'ID=18'), '/zh/news/news-6');
    assert.equal(await resolve('newsshow.asp', 'ID=24', 'en'), '/en/news/news-13');
    assert.equal(await resolve('newsshow.asp', 'ID=18', 'en'), null);
    assert.equal(await resolve('newsshow.asp', 'ID=14', 'en'), null);
    await db.news.update({ where: { slug: 'news-6' }, data: { published: false } });
    assert.equal(await resolve('newsshow.asp', 'ID=18'), null);
    await db.series.update({ where: { id: 'family' }, data: { published: false } });
    assert.equal(await resolve('productshow.asp', 'ID=607'), null);
    assert.equal(await resolve('Product.asp', 'SortID=8'), null);
  } finally { await db.$disconnect(); await fixture.dispose(); }
});

test('only known legacy page and section IDs map to the corresponding section', async () => {
  const resolve = (file: string, query = '', locale = 'zh') => resolveLegacyDestination(locale, file, new URLSearchParams(query));
  assert.equal(await resolve('index.asp'), '/zh');
  assert.equal(await resolve('index.asp', '', 'en'), '/en');
  assert.equal(await resolve('about.asp', 'id=1'), '/zh/about');
  assert.equal(await resolve('about.asp', 'id=2', 'en'), '/en/about');
  assert.equal(await resolve('about.asp', 'id=999'), null);
  assert.equal(await resolve('about.asp', 'id=4', 'en'), null);
  assert.equal(await resolve('contact.asp', 'id=11'), '/zh/contact');
  assert.equal(await resolve('join.asp', 'id=8'), '/zh/partners');
  assert.equal(await resolve('case.asp', 'id=6'), '/zh/cases');
  assert.equal(await resolve('faq.asp', 'Sortid=4', 'en'), '/en/resources#faq');
  assert.equal(await resolve('news.asp', 'SortID=2'), '/zh/news?category=industry');
  assert.equal(await resolve('news.asp', 'SortID=99'), null);
  assert.equal(await resolve('unknown.asp'), null);
});
