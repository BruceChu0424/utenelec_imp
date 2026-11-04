import assert from 'node:assert/strict';
import test from 'node:test';
import { PrismaClient } from '@prisma/client';
import { migratedDatabase } from './helpers/migrated-database';
import { createIsolatedPostgresqlDatabase, postgresqlTestsEnabled } from './helpers/isolated-postgresql';
import { productSearchPage } from '../lib/product-search';

async function contracts(db: PrismaClient, databaseUrl: string) {
  const previous = process.env.DATABASE_URL;
  process.env.DATABASE_URL = databaseUrl;
  try {
    await db.series.create({ data: { id: 'search-family', code: 'search-family', published: true, catalogRole: 'FAMILY', i18n: '{"en":{"name":"Family"}}' } });
    for (const [id, name, order, published] of [
      ['exact', 'Panel AB', 99, true], ['prefix', 'Panel ABC', 50, true], ['contains', 'Other Panel AB', 0, true],
      ['literal', 'A%_\\B', 0, true], ['decoy', 'AxZZB', 0, true], ['draft', 'Panel AB', 0, false],
    ] as const) await db.product.create({ data: { id, slug: id, seriesId: 'search-family', published, classificationStatus: 'VERIFIED', sortOrder: order, model: id === 'exact' ? 'GK11' : null,
      sceneEnabled: true, i18n: JSON.stringify({ en: { name }, zh: { name: `中文 ${id}` } }), variants: { create: { id: `v-${id}`, published: true, image: '/uploads/fixture.jpg', i18n: '{"en":{"name":"White"}}' } } } });
    await db.product.create({ data: { id: 'hidden-model', slug: 'hidden-model', seriesId: 'search-family', published: true, model: 'SECRET-MODEL', i18n: '{"en":{"name":"Ordinary"}}' } });
    await db.productVariant.create({ data: { id: 'hidden-variant', productId: 'exact', published: false, sku: 'secret-sku', i18n: '{"en":{"name":"Secret variant"}}' } });
    const scope = { query: ' panel\tAB panel ', locale: 'en', publicOnly: true, seriesIds: ['search-family'] };
    const first = await productSearchPage(db, scope, 0, 2, true);
    const second = await productSearchPage(db, scope, 2, 2);
    assert.equal(first.total, 3);
    assert.deepEqual([...first.ids, ...second.ids], ['exact', 'prefix', 'contains']);
    assert.deepEqual((await productSearchPage(db, { ...scope, query: '%_\\' }, 0, 24)).ids, ['literal']);
    assert.deepEqual((await productSearchPage(db, { ...scope, query: 'gk11' }, 0, 24)).ids, ['exact']);
    assert.equal((await productSearchPage(db, { ...scope, query: 'secret' }, 0, 24)).total, 0);
    assert.equal((await productSearchPage(db, { ...scope, query: 'name' }, 0, 24)).total, 0, 'JSON field keys are not product names');
    assert.equal((await productSearchPage(db, { ...scope, query: 'Panel', locale: 'zh' }, 0, 24)).total, 0, 'other translations do not override the displayed language');
    assert.deepEqual((await productSearchPage(db, { ...scope, query: 'GK11', internal: true, publicOnly: false }, 0, 24)).ids, ['exact']);
    assert.deepEqual((await productSearchPage(db, { query: 'secret-sku', internal: true, seriesIds: ['search-family'] }, 0, 24)).ids, ['exact']);
    assert.deepEqual((await productSearchPage(db, { ...scope, seriesIds: [], query: 'Panel' }, 0, 24)).ids, []);
  } finally { if (previous === undefined) delete process.env.DATABASE_URL; else process.env.DATABASE_URL = previous; }
}

test('literal, multilingual, ranked and bounded product searches on migrated SQLite', async () => {
  const fixture = await migratedDatabase();
  const db = new PrismaClient({ datasources: { db: { url: fixture.databaseUrl } } });
  try { await contracts(db, fixture.databaseUrl); } finally { await db.$disconnect(); await fixture.dispose(); }
});

test('the same product search contract on isolated PostgreSQL', { skip: !postgresqlTestsEnabled() }, async () => {
  const fixture = await createIsolatedPostgresqlDatabase('search');
  try { await contracts(fixture.client as unknown as PrismaClient, fixture.databaseUrl); } finally { await fixture.dispose(); }
});
