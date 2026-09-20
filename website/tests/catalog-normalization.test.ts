import assert from 'node:assert/strict';
import test from 'node:test';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { migratedDatabase, seedCatalog, websiteRoot, runNode, parseLastJsonObject } from './helpers/migrated-database';
import {
  buildCatalogNormalizationPlan,
  FAMILY_PUBLIC_SLUGS,
  type CatalogNormalizationInput,
} from '../scripts/lib/catalog-normalization';

const series = (
  id: string,
  overrides: Partial<CatalogNormalizationInput['series'][number]> = {},
): CatalogNormalizationInput['series'][number] => ({
  id,
  parentId: null,
  sourceIdentity: null,
  i18n: JSON.stringify({ en: { name: id } }),
  publicSlug: null,
  catalogRole: 'UNCLASSIFIED',
  published: false,
  rowVersion: 1,
  ...overrides,
});

const product = (
  id: string,
  overrides: Partial<CatalogNormalizationInput['products'][number]> = {},
): CatalogNormalizationInput['products'][number] => ({
  id,
  seriesId: null,
  i18n: JSON.stringify({ en: { name: 'Product' } }),
  functionType: null,
  gangCount: null,
  controlMode: null,
  classificationStatus: 'NEEDS_REVIEW',
  published: false,
  rowVersion: 1,
  ...overrides,
});

test('confirmed family source ids have the reviewed slug contract', () => {
  assert.deepEqual(Object.keys(FAMILY_PUBLIC_SLUGS), [
    '1', '2', '3', '4', '5', '6', '7', '9', '10', '11', '12',
    '53', '54', '61', '70', '75', '76', '77', '78', '79', '80', '81',
  ]);
  assert.equal(FAMILY_PUBLIC_SLUGS['53'], 'floor-socket');
  assert.equal(FAMILY_PUBLIC_SLUGS['77'], 'v4-white');
  assert.equal(FAMILY_PUBLIC_SLUGS['80'], 's300');
  assert.equal(FAMILY_PUBLIC_SLUGS['81'], 'z9');
});

test('normalization classifies source-backed navigation without publishing products or seed lookalikes', () => {
  const input: CatalogNormalizationInput = {
    series: [
      series('family', { sourceIdentity: 'ch-uten-v2:series:80' }),
      series('collection', { parentId: 'family', published: true }),
      series('container', { sourceIdentity: 'ch-uten-v2:series:60', published: true }),
      series('seed-s300', { i18n: JSON.stringify({ en: { name: 'S300 seed' } }) }),
    ],
    products: [
      product('published-child', {
        seriesId: 'collection',
        published: true,
        i18n: JSON.stringify({ en: { name: '2 gang two-way switch' } }),
      }),
      product('seed-product', { seriesId: 'seed-s300', published: false }),
    ],
    variants: [],
  };

  const plan = buildCatalogNormalizationPlan(input);
  const family = plan.seriesUpdates.find((item) => item.id === 'family');
  const collection = plan.seriesUpdates.find((item) => item.id === 'collection');
  const container = plan.seriesUpdates.find((item) => item.id === 'container');
  assert.deepEqual(family?.data, { catalogRole: 'FAMILY', publicSlug: 's300', published: true });
  assert.deepEqual(collection?.data, { catalogRole: 'COLLECTION' });
  assert.deepEqual(container?.data, { catalogRole: 'CONTAINER', published: false });
  assert.equal(plan.seriesUpdates.some((item) => item.id === 'seed-s300'), false);
  assert.equal(plan.summary.familiesToPublish, 1);
  assert.equal(input.products[1].published, false);
  assert.equal(input.products[1].seriesId, 'seed-s300');

  const inferred = plan.productUpdates.find((item) => item.id === 'published-child');
  assert.deepEqual(inferred?.data, {
    functionType: 'switches',
    gangCount: 2,
    controlMode: 'TWO_WAY',
    classificationStatus: 'INFERRED',
  });
});

test('only exact imported base variants become synthetic defaults', () => {
  const plan = buildCatalogNormalizationPlan({
    series: [],
    products: [product('p1'), product('p2')],
    variants: [
      {
        id: 'base',
        productId: 'p1',
        sourceIdentity: 'ch-uten-v2:variant:123:base',
        legacySynthetic: false,
        dataStatus: 'INFERRED',
        isDefault: false,
      },
      {
        id: 'explicit',
        productId: 'p2',
        sourceIdentity: 'ch-uten-v2:variant:123:gold',
        legacySynthetic: false,
        dataStatus: 'NEEDS_REVIEW',
        isDefault: false,
      },
    ],
  });

  assert.deepEqual(plan.variantUpdates, [{
    id: 'base',
    productId: 'p1',
    data: { legacySynthetic: true, dataStatus: 'NEEDS_REVIEW', isDefault: true },
  }]);
  assert.equal(plan.summary.legacySyntheticVariants, 1);
});

test('verified editor classifications are never overwritten by inference', () => {
  const plan = buildCatalogNormalizationPlan({
    series: [],
    products: [product('verified', {
      i18n: JSON.stringify({ en: { name: '2 gang switch' } }),
      functionType: 'accessories',
      classificationStatus: 'VERIFIED',
    })],
    variants: [],
  });
  assert.deepEqual(plan.productUpdates, []);
});

test('normalization reports public slug collisions instead of stealing a manual slug', () => {
  const plan = buildCatalogNormalizationPlan({
    series: [
      series('source-family', { sourceIdentity: 'ch-uten-v2:series:80' }),
      series('manual', { publicSlug: 's300' }),
    ],
    products: [],
    variants: [],
  });
  assert.equal(plan.issues.length, 1);
  assert.match(plan.issues[0], /already owned/);
});

test('migrated SQLite fixture preserves nonempty identities, content and ownership', { timeout: 120_000 }, async () => {
  const fixture = await migratedDatabase();
  const { databasePath, databaseUrl } = fixture;
  const snapshotScript = path.join(websiteRoot, 'tests', 'helpers', 'catalog-snapshot-query.js');
  const snapshot = () => {
    const result = runNode(snapshotScript, [], { DATABASE_URL: databaseUrl });
    return parseLastJsonObject<{
      seriesRows: Array<{ id: string; sourceIdentity: string | null; parentId: string | null }>;
      productRows: Array<{ id: string; sourceIdentity: string | null; seriesId: string | null; published: boolean }>;
      variantRows: Array<{ id: string; sourceIdentity: string | null; productId: string }>;
      sourceAudit: { count: number; digest: string };
      normalized: { families: number; collections: number; inferredProducts: number; syntheticVariants: number };
    }>(result.stdout);
  };

  try {
    await seedCatalog(databaseUrl);
    const before = snapshot();
    assert.equal(before.seriesRows.length, 4);
    assert.equal(before.productRows.length, 2);
    assert.equal(before.variantRows.length, 2);
    assert.equal(before.sourceAudit.count, 3);
    const digest = (value: Buffer) => createHash('sha256').update(value).digest('hex');
    const beforeDigest = digest(await readFile(databasePath));
    runNode(path.join(websiteRoot, 'node_modules/tsx/dist/cli.mjs'),
      [path.join(websiteRoot, 'prisma/normalize-product-catalog.ts'), '--database', databasePath]);
    assert.equal(digest(await readFile(databasePath)), beforeDigest, 'dry-run cannot write fixture state');
    const firstApply = runNode(
      path.join(websiteRoot, 'node_modules', 'tsx', 'dist', 'cli.mjs'),
      [path.join(websiteRoot, 'prisma', 'normalize-product-catalog.ts'), '--apply', '--database', databasePath],
      {
        UTEN_CATALOG_NORMALIZATION_CONFIRM: 'APPLY_REVIEWED_CATALOG_NORMALIZATION',
      },
    );
    const firstResult = parseLastJsonObject<{ summary: { collectionCount: number };
      changes: { series: number; products: number; variants: number }; backupPath: string; auditPath: string }>(firstApply.stdout);
    assert.ok(firstResult.changes.series > 0);
    assert.equal(firstResult.changes.products, 1);
    assert.equal(firstResult.changes.variants, 1);
    assert.ok((await readFile(firstResult.backupPath)).length > 0);
    assert.ok((await readFile(firstResult.auditPath)).length > 0);
    const after = snapshot();
    assert.deepEqual(after.seriesRows, before.seriesRows);
    assert.deepEqual(after.productRows, before.productRows);
    assert.deepEqual(after.variantRows, before.variantRows);
    assert.deepEqual(after.sourceAudit, before.sourceAudit);
    assert.deepEqual(after.normalized, { families: 2, collections: 1, inferredProducts: 1, syntheticVariants: 1 });
    assert.equal(after.seriesRows.length, before.seriesRows.length);
    assert.equal(after.productRows.length, before.productRows.length);
    assert.equal(after.variantRows.length, before.variantRows.length);
    const secondApply = runNode(
      path.join(websiteRoot, 'node_modules', 'tsx', 'dist', 'cli.mjs'),
      [path.join(websiteRoot, 'prisma', 'normalize-product-catalog.ts'), '--apply', '--database', databasePath],
      {
        UTEN_CATALOG_NORMALIZATION_CONFIRM: 'APPLY_REVIEWED_CATALOG_NORMALIZATION',
      },
    );
    const secondResult = parseLastJsonObject<{
      changes: { series: number; products: number; variants: number };
      summary: { collectionCount: number };
    }>(secondApply.stdout);
    assert.deepEqual(secondResult.changes, { series: 0, products: 0, variants: 0 });
    assert.equal(secondResult.summary.collectionCount, firstResult.summary.collectionCount);
    assert.deepEqual(snapshot(), after);
  } finally {
    await fixture.dispose();
  }
});
