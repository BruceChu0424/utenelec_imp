import assert from 'node:assert/strict';
import test from 'node:test';
import { PrismaClient } from '@prisma/client';
import { migratedDatabase } from './helpers/migrated-database';

test('public documents preserve product, collection and family scope with complete database pagination', async (t) => {
  const fixture = await migratedDatabase();
  const previousUrl = process.env.DATABASE_URL;
  process.env.DATABASE_URL = fixture.databaseUrl;
  const db = new PrismaClient({ datasources: { db: { url: fixture.databaseUrl } } });
  const { prisma } = await import('../lib/db');
  const { queryPublicResources, publicResourceWhere, resourcePageHref } = await import('../lib/resources');
  try {
    await db.series.createMany({ data: [
      { id: 'family', code: 'family', catalogRole: 'FAMILY', published: true, i18n: '{}' },
      { id: 'other-family', code: 'other-family', catalogRole: 'FAMILY', published: true, i18n: '{}' },
      { id: 'hidden-family', code: 'hidden-family', catalogRole: 'FAMILY', published: false, i18n: '{}' },
    ] });
    await db.series.create({ data: { id: 'collection', code: 'collection', catalogRole: 'COLLECTION', parentId: 'family', published: true, i18n: '{}' } });
    for (const [id, seriesId, published] of [
      ['selected', 'collection', true], ['other', 'collection', true], ['draft', 'collection', false],
      ['hidden-child', 'hidden-family', true],
    ] as const) await db.product.create({ data: { id, slug: id, seriesId, published, i18n: '{}' } });
    await db.websiteDocumentAsset.create({ data: {
      id: 'document', storageKey: 'a'.repeat(48) + '.pdf', sha256: 'a'.repeat(64), mimeType: 'application/pdf',
      originalName: 'scope-fixture.pdf', sizeBytes: 123, createdBy: 'synthetic-test',
    } });
    const resource = (id: string, extra: { productId?: string; seriesId?: string; published?: boolean; language?: string } = {}) =>
      db.resourceDocument.create({ data: { id, slug: id, assetId: 'document', language: 'en', version: '1',
        i18n: JSON.stringify({ en: { title: id } }), published: true, ...extra } });
    await resource('global');
    await resource('family-guide', { seriesId: 'family' });
    await resource('collection-guide', { seriesId: 'collection' });
    await resource('selected-guide', { productId: 'selected' });
    await resource('selected-guide-both', { productId: 'selected', seriesId: 'collection' });
    await resource('other-guide', { productId: 'other', seriesId: 'collection' });
    await resource('other-family-guide', { seriesId: 'other-family' });
    await resource('draft-guide', { productId: 'draft' });
    await resource('hidden-family-guide', { seriesId: 'hidden-family' });
    await resource('hidden-child-guide', { productId: 'hidden-child' });
    await resource('unpublished-guide', { published: false });
    await resource('unrelated-language', { language: 'fr' });

    await t.test('product details include applicable general and ancestor documents but never another product document', async () => {
      const result = await queryPublicResources('en', { productId: 'selected' });
      assert.equal(result.total, 5);
      assert.deepEqual(result.items.map(item => item.id).sort(),
        ['collection-guide', 'family-guide', 'global', 'selected-guide', 'selected-guide-both']);
      const other = await queryPublicResources('en', { productId: 'other' });
      assert.equal(other.total, 4);
      assert.equal(other.items.some(item => item.id.startsWith('selected-')), false);
      assert.equal(result.items[0].href.startsWith('/api/resources/'), true);
      assert.equal('storageKey' in result.items[0], false);
    });

    await t.test('hidden or unknown product contexts return no general fallback documents', async () => {
      for (const productId of ['draft', 'hidden-child', 'unknown'])
        assert.equal((await queryPublicResources('en', { productId })).total, 0);
      assert.equal(await db.resourceDocument.count({ where: { id: 'hidden-child-guide', ...publicResourceWhere() } }), 0);
      assert.equal(await db.resourceDocument.count({ where: { id: 'hidden-family-guide', ...publicResourceWhere() } }), 0);
    });

    await t.test('more than the former 100-document ceiling remains reachable without unbounded responses', async () => {
      for (let i = 0; i < 105; i++) await resource(`library-${String(i).padStart(3, '0')}`);
      const first = await queryPublicResources('en');
      assert.equal(first.total, 112);
      assert.equal(first.pages, 5);
      const all = [];
      for (let page = 1; page <= first.pages; page++) {
        const result = await queryPublicResources('en', { page });
        assert.equal(result.total, first.total);
        assert.ok(result.items.length <= 24);
        all.push(...result.items);
      }
      assert.equal(all.length, first.total);
      assert.equal(new Set(all.map(item => item.id)).size, first.total);
      assert.ok(all.some(item => item.id === 'library-104'));
      assert.equal((await queryPublicResources('en', { page: -1 })).page, 1);
      assert.equal((await queryPublicResources('en', { page: Number.POSITIVE_INFINITY })).page, 1);
      assert.equal((await queryPublicResources('en', { page: 999 })).page, first.pages);
      assert.equal(resourcePageHref('/products/family/model?variant=chosen', 2),
        '/products/family/model?variant=chosen&documentsPage=2#documents');
      assert.equal(resourcePageHref('/resources?documentsPage=2', 1), '/resources#documents');
    });

    await t.test('taking a parent family offline removes the full linked hierarchy from both query and download guard', async () => {
      await db.series.update({ where: { id: 'family' }, data: { published: false } });
      assert.equal((await queryPublicResources('en', { productId: 'selected' })).total, 0);
      for (const id of ['family-guide', 'collection-guide', 'selected-guide', 'selected-guide-both', 'other-guide'])
        assert.equal(await db.resourceDocument.count({ where: { id, ...publicResourceWhere() } }), 0);
      assert.equal(await db.resourceDocument.count({ where: { id: 'global', ...publicResourceWhere() } }), 1);
      assert.equal(await db.resourceDocument.count({ where: { id: 'other-family-guide', ...publicResourceWhere() } }), 1);
    });
  } finally {
    await prisma.$disconnect();
    await db.$disconnect();
    if (previousUrl === undefined) delete process.env.DATABASE_URL;
    else process.env.DATABASE_URL = previousUrl;
    await fixture.dispose();
  }
});
