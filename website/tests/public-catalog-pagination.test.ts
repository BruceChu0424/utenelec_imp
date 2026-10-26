import assert from 'node:assert/strict';
import test from 'node:test';
import { PrismaClient } from '@prisma/client';
import { migratedDatabase } from './helpers/migrated-database';
import { catalogWindow, catalogTextFilter } from '../lib/catalog-query';
import { publicProductView, productContactHref } from '../lib/public-product';
import type { ProductWithRelations } from '../lib/catalog';

test('public catalog uses complete database pages and publication-aware context', async (t) => {
  const fixture = await migratedDatabase();
  const previousUrl = process.env.DATABASE_URL;
  process.env.DATABASE_URL = fixture.databaseUrl;
  const db = new PrismaClient({ datasources: { db: { url: fixture.databaseUrl } } });
  const { prisma } = await import('../lib/db');
  try {
    await db.series.create({ data: { id: 'f', code: 'family', publicSlug: 'public-family', catalogRole: 'FAMILY', published: true, i18n: '{"en":{"name":"Public family"}}' } });
    await db.series.create({ data: { id: 'c', code: 'collection', catalogRole: 'COLLECTION', parentId: 'f', published: true, i18n: '{"en":{"name":"Collection"}}' } });
    await db.series.create({ data: { id: 'private-family', code: 'private-family', catalogRole: 'FAMILY', published: false, i18n: '{}' } });
    for (let i = 0; i < 60; i++) await db.product.create({ data: { id: `p-${i}`, slug: `p-${i}`, seriesId: 'c', sortOrder: i, functionType: i % 3 ? 'switches' : 'power-sockets', gangCount: i % 2 + 1, i18n: JSON.stringify({ en: { name: `Model ${i}` } }), published: true } });
    await db.product.create({ data: { id: 'unknown', slug: 'unknown', seriesId: 'c', sortOrder: 100, i18n: '{"en":{"name":"Switch name without a reviewed classification"}}', published: true } });
    await db.product.create({ data: { id: 'draft', slug: 'draft', seriesId: 'c', i18n: '{"en":{"name":"Draft"}}', published: false } });
    await db.product.create({ data: { id: 'private-child', slug: 'private-child', seriesId: 'private-family', i18n: '{}', published: true } });
    await db.productVariant.create({ data: { id: 'v-0', productId: 'p-0', i18n: '{"en":{"name":"Visible"}}', published: true } });
    await db.productVariant.create({ data: { id: 'hidden-v', productId: 'p-0', i18n: '{}', published: false } });
    const { queryCatalogProducts, getCatalogNavigation, getPublicInquiryContext, queryStudioProducts } = await import('../lib/queries');
    await t.test('all pages retain unique identities and a consistent total', async () => {
      const pages = await Promise.all([0, 24, 48].map(offset => queryCatalogProducts({ locale: 'en', familyIdentifier: 'public-family', offset, take: 24 })));
      assert.deepEqual(pages.map(page => page?.products.length), [24, 24, 13]);
      assert.ok(pages.every(page => page?.total === 61));
      const ids = pages.flatMap(page => page!.products.map(product => product.id));
      assert.equal(new Set(ids).size, 61);
      assert.deepEqual(ids.slice(0, 3), ['p-0', 'p-1', 'p-2']);
      assert.equal(ids.includes('draft'), false);
      assert.equal(ids.includes('private-child'), false);
    });
    await t.test('SQL search, typed facets and unclassified fallback agree', async () => {
      const result = await queryCatalogProducts({ locale: 'en', familyIdentifier: 'public-family', query: 'Model 1', take: 5 });
      assert.equal(result?.total, 11);
      assert.equal(result?.products.length, 5);
      const unknown = await queryCatalogProducts({ locale: 'en', familyIdentifier: 'public-family', functionType: 'other' });
      assert.deepEqual(unknown?.products.map(product => [product.id, product.functionType]), [['unknown', 'other']]);
      const switches = await queryCatalogProducts({ locale: 'en', familyIdentifier: 'public-family', functionType: 'switches', gangCount: 2 });
      assert.equal(switches?.total, 20);
      assert.ok(switches?.products.every(product => product.functionType === 'switches' && product.gangCount === 2));
    });
    await t.test('navigation does not fetch product/variant payloads', async () => {
      const navigation = await getCatalogNavigation();
      assert.equal(navigation.length, 1);
      assert.equal('products' in navigation[0], false);
      assert.equal('media' in navigation[0], false);
      assert.equal('products' in navigation[0].children[0], false);
    });
    await t.test('studio pages are bounded, preserve deep links and exclude floor sockets', async () => {
      await db.product.updateMany({ where: { id: { startsWith: 'p-' } }, data: { sceneEnabled: true } });
      await db.productVariant.update({ where: { id: 'v-0' }, data: { image: '/uploads/fixture-0.jpg' } });
      for (let i = 1; i < 60; i++) await db.productVariant.create({ data: { id: `v-${i}`, productId: `p-${i}`, i18n: '{}', image: `/uploads/fixture-${i}.jpg`, published: true } });
      await db.series.create({ data: { id: 'floor', code: 'floor-socket', publicSlug: 'floor-socket', catalogRole: 'FAMILY', published: true, sourceIdentity: 'ch-uten-v2:series:53', i18n: '{}' } });
      await db.product.create({ data: { id: 'floor-product', slug: 'floor-product', seriesId: 'floor', published: true, sceneEnabled: true, i18n: '{}', variants: { create: { id: 'floor-variant', i18n: '{}', image: '/uploads/floor.jpg', published: true } } } });
      const second = await queryStudioProducts({ offset: 24 });
      assert.equal(second.total, 60);
      assert.equal(second.products.length, 24);
      const pinned = await queryStudioProducts({ variantId: 'v-59' });
      assert.equal(pinned.products.length, 25);
      assert.equal(pinned.products[0].id, 'p-59');
      assert.equal(pinned.selected?.id, 'p-59');
      assert.equal((await queryStudioProducts({ variantId: 'floor-variant' })).selected, null);
    });
    await t.test('contact context cannot bind an unpublished or unrelated target', async () => {
      assert.equal(await getPublicInquiryContext({ productId: 'draft' }, 'en'), null);
      assert.equal(await getPublicInquiryContext({ productId: 'private-child' }, 'en'), null);
      assert.equal(await getPublicInquiryContext({ productId: 'p-0', variantId: 'hidden-v' }, 'en'), null);
      assert.equal(await getPublicInquiryContext({ productId: 'p-0', seriesId: 'private-family' }, 'en'), null);
      assert.equal((await getPublicInquiryContext({ productId: 'p-0', variantId: 'v-0' }, 'en'))?.context.variantId, 'v-0');
      await db.series.update({ where: { id: 'f' }, data: { published: false } });
      assert.equal(await queryCatalogProducts({ locale: 'en', familyIdentifier: 'public-family' }), null);
      assert.equal(await getPublicInquiryContext({ productId: 'p-0' }, 'en'), null);
    });
  } finally {
    await prisma.$disconnect(); await db.$disconnect();
    if (previousUrl === undefined) delete process.env.DATABASE_URL; else process.env.DATABASE_URL = previousUrl;
    await fixture.dispose();
  }
});

test('historical descriptions remain readable while synthetic specifications stay hidden', () => {
  const product = { id: 'p', slug: 'legacy-p', legacySource: 'ch-uten-v2', classificationStatus: 'VERIFIED', model: 'P', i18n: '{"en":{"name":"Panel","description":"Legacy packaging: 8 per box."}}', specs: '{"en":[{"label":"Confirmed field","value":"Confirmed value"}]}', variants: [{ id: 'v', published: true, image: '/uploads/image.jpg', i18n: '{"en":{"name":"Legacy base"}}', dataStatus: 'VERIFIED', legacySynthetic: true, widthMm: 86, heightMm: 86, finish: 'Unverified finish', swatchHex: '#fff' }] } as unknown as ProductWithRelations;
  const view = publicProductView(product, 'en');
  assert.equal(view.historicalDescription, 'Legacy packaging: 8 per box.');
  assert.equal(view.variants[0].widthMm, null);
  assert.equal(view.variants[0].finish, null);
  assert.equal(view.variants[0].swatchHex, null);
  assert.equal('price' in view, false);
  product.classificationStatus = 'NEEDS_REVIEW';
  const draftView = publicProductView(product, 'en');
  assert.deepEqual(draftView.specs, []);
  assert.equal(draftView.description, undefined);
  assert.equal(draftView.historicalDescription, 'Legacy packaging: 8 per box.');
  product.classificationStatus = 'VERIFIED';
  product.variants[0].legacySynthetic = false;
  product.variants[0].finish = 'Reviewed finish';
  const approvedView = publicProductView(product, 'en');
  assert.equal(approvedView.variants[0].widthMm, 86);
  assert.equal(approvedView.variants[0].finish, 'Reviewed finish');
  assert.equal(approvedView.specs.length, 1);
  product.variants[0].dataStatus = 'NEEDS_REVIEW';
  assert.equal(publicProductView(product, 'en').variants[0].widthMm, null);
});

test('contact URLs retain stable source IDs and pagination clamps hostile values', () => {
  assert.equal(productContactHref({ productId: 'p/1', variantId: 'v 2', seriesId: 's' }), '/contact?source=product&productId=p%2F1&variantId=v+2&seriesId=s');
  assert.equal(new URL(productContactHref({ productId: 'p', variantId: 'p-default' }), 'https://example.invalid').searchParams.has('variantId'), false);
  assert.deepEqual(catalogWindow(-1, 5000), { skip: 0, take: 48 });
  assert.deepEqual(catalogWindow(Number.NaN, Number.NaN), { skip: 0, take: 24 });
});

test('catalog search preserves case-insensitive behavior for both SQL providers', () => {
  assert.deepEqual(catalogTextFilter('gk11', false), { contains: 'gk11' });
  assert.deepEqual(catalogTextFilter('gk11', true), { contains: 'gk11', mode: 'insensitive' });
});
