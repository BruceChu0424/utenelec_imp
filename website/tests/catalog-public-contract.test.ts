import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

import {
  catalogFamilyForSeries,
  catalogFamilySlug,
  catalogSeriesIdentifiers,
  resolveProductTaxonomy,
  selectRepresentativeFamilyProducts,
  toCatalogFamily,
  toCatalogProduct,
  toStudioVariants,
  type CatalogFamilyProductPreview,
  type CatalogFamilyRecord,
  type CatalogSeriesIdentity,
  type ProductWithRelations,
} from '../lib/catalog';
import { inferProductTaxonomy } from '../lib/product-taxonomy';
import {
  catalogProductRedirectTarget,
  catalogSeriesRedirectTarget,
} from '../lib/catalog-routing';

const timestamp = new Date('2026-08-09T00:00:00.000Z');

function localized(zh: Record<string, string>, en: Record<string, string> = {}): string {
  return JSON.stringify({ zh, en });
}

function series(
  id: string,
  overrides: Partial<CatalogSeriesIdentity> = {},
): CatalogSeriesIdentity {
  return {
    id,
    code: id,
    publicSlug: null,
    catalogRole: 'UNCLASSIFIED',
    rowVersion: 1,
    i18n: localized({ name: id }),
    coverImage: null,
    sortOrder: 0,
    published: true,
    sourceIdentity: null,
    legacySource: null,
    legacyId: null,
    parentId: null,
    createdAt: timestamp,
    updatedAt: timestamp,
    ...overrides,
  } as CatalogSeriesIdentity;
}

function preview(
  id: string,
  image: string,
  sortOrder = 0,
  taxonomy: { functionType?: string | null; gangCount?: number | null; name?: string } = {},
): CatalogFamilyProductPreview {
  return {
    id,
    slug: id,
    image,
    i18n: localized({ name: taxonomy.name || id }),
    sortOrder,
    functionType: taxonomy.functionType,
    gangCount: taxonomy.gangCount,
    variants: [],
  };
}

function productFixture({
  family,
  collection,
  name = 'S300 一开单控开关',
  classificationStatus = 'NEEDS_REVIEW',
  functionType = null,
  variantId = 'legacy base/1084',
}: {
  family: CatalogSeriesIdentity;
  collection: CatalogSeriesIdentity;
  name?: string;
  classificationStatus?: string;
  functionType?: string | null;
  variantId?: string;
}): ProductWithRelations {
  return {
    id: 'product-1084',
    seriesId: collection.id,
    slug: 'legacy-v2-1084',
    model: 'UNVERIFIED-1084',
    category: 'legacy:internal-category',
    functionType,
    gangCount: null,
    controlMode: null,
    configuration: '20A 250V',
    classificationStatus,
    rowVersion: 1,
    image: '/uploads/s300/1084.jpg',
    gallery: null,
    specs: null,
    i18n: localized(
      { name, description: '旧资料称 20A 250V，每箱 80 只。' },
      { name: 'S300 one-gang switch', description: 'Legacy copy claims 20A 250V and 80 pieces per carton.' },
    ),
    minOrderQty: null,
    sceneEnabled: true,
    featured: false,
    sortOrder: 0,
    published: true,
    sourceIdentity: 'ch-uten-v2:product:1084',
    legacySource: 'ch-uten-v2',
    legacyId: '1084',
    createdAt: timestamp,
    updatedAt: timestamp,
    series: {
      ...collection,
      parent: family,
    },
    variants: [
      {
        id: variantId,
        productId: 'product-1084',
        sku: null,
        i18n: localized({ name: '标准款' }, { name: 'Standard' }),
        swatchHex: '#c0c0c0',
        image: '/uploads/s300/1084.jpg',
        gallery: null,
        finish: null,
        widthMm: null,
        heightMm: null,
        depthMm: null,
        legacySynthetic: true,
        dataStatus: 'NEEDS_REVIEW',
        isDefault: true,
        published: true,
        sortOrder: 0,
        sourceIdentity: 'ch-uten-v2:variant:1084:base',
        legacySource: 'ch-uten-v2',
        legacyId: 'base',
        createdAt: timestamp,
        updatedAt: timestamp,
      },
    ],
  } as unknown as ProductWithRelations;
}

function s300Hierarchy(): {
  family: CatalogSeriesIdentity;
  collection: CatalogSeriesIdentity;
} {
  const family = series('series-80', {
    code: 'legacy-v2-80',
    publicSlug: 's300',
    catalogRole: 'FAMILY',
    i18n: localized({ name: 'S300 系列' }, { name: 'S300 Series' }),
    sourceIdentity: 'ch-uten-v2:series:80',
  });
  const collection = series('series-80-switches', {
    code: 'legacy-v2-80-switches',
    catalogRole: 'COLLECTION',
    parentId: family.id,
    i18n: localized({ name: '开关功能' }, { name: 'Switches' }),
  });
  return { family, collection };
}

test('a collection product resolves to its FAMILY and clean public slug', () => {
  const { family, collection } = s300Hierarchy();
  const collectionWithParent = { ...collection, parent: family };

  assert.equal(catalogFamilyForSeries(collectionWithParent)?.id, family.id);
  assert.equal(catalogFamilySlug(collectionWithParent), 's300');
  assert.deepEqual(
    [...catalogSeriesIdentifiers(collectionWithParent)].sort(),
    ['legacy-v2-80', 'legacy-v2-80-switches', 's300'],
  );
});

test('catalog and studio links use the FAMILY slug and preserve a variant deep link', () => {
  const { family, collection } = s300Hierarchy();
  const product = productFixture({ family, collection });
  const catalogProduct = toCatalogProduct(product, 'zh', '标准款');
  const [studioVariant] = toStudioVariants([product], 'zh', '标准款');

  assert.equal(catalogProduct.href, '/products/s300/legacy-v2-1084');
  assert.equal(catalogProduct.seriesCode, 's300');
  assert.equal(
    studioVariant.productHref,
    '/products/s300/legacy-v2-1084?variant=legacy%20base%2F1084',
  );
});

test('a synthetic legacy base remains an image fallback, not a claimed SKU or color', () => {
  const { family, collection } = s300Hierarchy();
  const product = productFixture({ family, collection });
  const publicProduct = toCatalogProduct(product, 'zh', '标准款');
  const publicVariant = publicProduct.variants[0];
  const studioVariant = toStudioVariants([product], 'zh', '标准款')[0];

  assert.equal(publicProduct.model, null);
  assert.equal(publicProduct.category, null);
  assert.equal(publicProduct.description, undefined);
  assert.equal(publicProduct.controlMode, null);
  assert.equal(publicProduct.configuration, null);
  assert.equal(publicVariant.swatchHex, null);
  assert.equal('sku' in publicVariant, false);
  assert.equal(studioVariant.legacySynthetic, true);
  assert.equal(studioVariant.swatchHex, null);
  assert.equal(studioVariant.finish, null);
  assert.equal(studioVariant.widthMm, null);
  assert.equal(studioVariant.heightMm, null);
  assert.equal(studioVariant.model, null);
});

test('S300 name evidence creates INFERRED review candidates for gangs and functions', () => {
  const cases = [
    { name: 'S300 一开单控开关', functionType: 'switches', gangCount: 1, controlMode: 'ONE_WAY' },
    { name: 'S300 二开双控开关', functionType: 'switches', gangCount: 2, controlMode: 'TWO_WAY' },
    { name: 'S300 三开多控开关', functionType: 'switches', gangCount: 3, controlMode: 'MULTIWAY' },
    { name: 'S300 五孔插座', functionType: 'power-sockets', gangCount: null, controlMode: null },
    { name: 'S300 USB Type-C 充电插座', functionType: 'usb-charging', gangCount: null, controlMode: null },
    { name: 'S300 酒店请勿打扰门铃开关', functionType: 'hospitality', gangCount: null, controlMode: null },
  ] as const;

  for (const expected of cases) {
    assert.deepEqual(inferProductTaxonomy([expected.name]), {
      functionType: expected.functionType,
      gangCount: expected.gangCount,
      controlMode: expected.controlMode,
      status: 'INFERRED',
    });
  }
});

test('a FAMILY collage aggregates direct and child products without promoting the COLLECTION', () => {
  const { family, collection } = s300Hierarchy();
  const familyRecord = {
    ...family,
    parent: null,
    coverImage: null,
    media: [],
    products: [preview('direct-product', '/uploads/s300/direct.jpg')],
    children: [
      {
        ...collection,
        parent: family,
        products: [
          preview('child-product', '/uploads/s300/child.jpg'),
          preview('duplicate-product', '/uploads/s300/child.jpg', 1),
        ],
        _count: { products: 3 },
      },
    ],
    _count: { products: 2 },
  } as CatalogFamilyRecord;

  const view = toCatalogFamily(familyRecord, 'zh');

  assert.equal(view.slug, 's300');
  assert.equal(view.count, 5);
  assert.deepEqual(view.collections, [{ id: collection.id, name: '开关功能', count: 3 }]);
  assert.deepEqual(
    view.images.map((item) => `${item.kind}:${item.src}`).sort(),
    [
      'product:/uploads/s300/child.jpg',
      'product:/uploads/s300/direct.jpg',
    ],
  );
  assert.equal(catalogFamilyForSeries({ ...collection, parent: family })?.catalogRole, 'FAMILY');
});

test('a curated combination cover is the authoritative series-card image', () => {
  const { family } = s300Hierarchy();
  const familyRecord = {
    ...family,
    parent: null,
    coverImage: '/uploads/s300/series-combination.webp',
    media: [
      {
        id: 'hero-media',
        role: 'hero',
        image: '/uploads/s300/room-hero.webp',
        i18n: '{}',
        sortOrder: 0,
        published: true,
      },
    ],
    products: [preview('source-product', '/uploads/s300/product.jpg')],
    children: [],
    _count: { products: 1 },
  } as CatalogFamilyRecord;

  const view = toCatalogFamily(familyRecord, 'zh');
  assert.deepEqual(view.images[0], {
    src: '/uploads/s300/series-combination.webp',
    kind: 'editorial',
  });
  assert.equal(view.hasEditorialMedia, true);
});

test('an explicit COMBINATION media item outranks legacy cover and other editorial media', () => {
  const { family } = s300Hierarchy();
  const familyRecord = {
    ...family,
    parent: null,
    coverImage: '/uploads/s300/legacy-cover.webp',
    media: [
      {
        id: 'hero-media',
        role: 'HERO',
        image: '/uploads/s300/room-hero.webp',
        i18n: '{}',
        sortOrder: 0,
        published: true,
      },
      {
        id: 'combination-media',
        role: 'COMBINATION',
        image: '/uploads/s300/curated-family-cover.webp',
        i18n: '{}',
        sortOrder: 8,
        published: true,
      },
    ],
    products: [preview('source-product', '/uploads/s300/product.jpg')],
    children: [],
    _count: { products: 1 },
  } as CatalogFamilyRecord;

  const view = toCatalogFamily(familyRecord, 'zh');
  assert.deepEqual(view.images, [{
    src: '/uploads/s300/curated-family-cover.webp',
    kind: 'editorial',
  }]);
});

test('hero or lifestyle media never silently replaces the series combination cover', () => {
  const { family } = s300Hierarchy();
  const familyRecord = {
    ...family,
    parent: null,
    coverImage: null,
    media: [
      {
        id: 'hero-media',
        role: 'HERO',
        image: '/uploads/s300/room-hero.webp',
        i18n: '{}',
        sortOrder: 0,
        published: true,
      },
      {
        id: 'lifestyle-media',
        role: 'LIFESTYLE',
        image: '/uploads/s300/lifestyle.webp',
        i18n: '{}',
        sortOrder: 1,
        published: true,
      },
    ],
    products: [preview('source-product', '/uploads/s300/product.jpg')],
    children: [],
    _count: { products: 1 },
  } as CatalogFamilyRecord;

  const view = toCatalogFamily(familyRecord, 'zh');
  assert.deepEqual(view.images, [{
    src: '/uploads/s300/product.jpg',
    kind: 'product',
  }]);
  assert.equal(view.hasEditorialMedia, false);
});

test('fallback family cover represents gang progression and another real function', () => {
  const products = [
    preview('gang-1', '/uploads/s300/gang-1.jpg', 1, { functionType: 'switches', gangCount: 1 }),
    preview('gang-2', '/uploads/s300/gang-2.jpg', 2, { functionType: 'switches', gangCount: 2 }),
    preview('gang-3', '/uploads/s300/gang-3.jpg', 3, { functionType: 'switches', gangCount: 3 }),
    preview('gang-4', '/uploads/s300/gang-4.jpg', 4, { functionType: 'switches', gangCount: 4 }),
    preview('socket', '/uploads/s300/socket.jpg', 20, { functionType: 'power-sockets' }),
    preview('usb', '/uploads/s300/usb.jpg', 21, { functionType: 'usb-charging' }),
  ];

  assert.deepEqual(
    selectRepresentativeFamilyProducts(products).map((product) => product.id),
    ['gang-1', 'gang-2', 'gang-3', 'socket'],
  );
});

test('fallback family cover de-duplicates source images without inventing replacements', () => {
  const products = [
    preview('gang-1', '/uploads/s300/shared.jpg', 1, { functionType: 'switches', gangCount: 1 }),
    preview('gang-2-copy', '/uploads/s300/shared.jpg', 2, { functionType: 'switches', gangCount: 2 }),
    preview('socket', '/uploads/s300/socket.jpg', 3, { functionType: 'power-sockets' }),
  ];

  const selected = selectRepresentativeFamilyProducts(products);
  assert.deepEqual(selected.map((product) => product.id), ['gang-1', 'socket']);
  assert.deepEqual(selected.map((product) => product.image), [
    '/uploads/s300/shared.jpg',
    '/uploads/s300/socket.jpg',
  ]);
});

test('missing evidence and editor-marked conflicts stay NEEDS_REVIEW', () => {
  assert.deepEqual(inferProductTaxonomy([], []), {
    functionType: 'other',
    gangCount: null,
    controlMode: null,
    status: 'NEEDS_REVIEW',
  });

  const { family, collection } = s300Hierarchy();
  const conflictingProduct = productFixture({
    family,
    collection,
    name: 'S300 USB 五孔插座',
    functionType: 'switches',
    classificationStatus: 'NEEDS_REVIEW',
  });

  assert.deepEqual(resolveProductTaxonomy(conflictingProduct, 'zh'), {
    functionType: 'switches',
    gangCount: null,
    controlMode: null,
    status: 'NEEDS_REVIEW',
  });
});

test('legacy catalog URLs redirect to the locale-preserving canonical family', () => {
  assert.equal(catalogProductRedirectTarget({
    locale: 'zh',
    requestedFamily: 'legacy-v2-80',
    canonicalFamily: 's300',
    productSlug: 'legacy-v2-1084',
  }), '/zh/products/s300/legacy-v2-1084');

  assert.equal(catalogProductRedirectTarget({
    locale: 'en',
    requestedFamily: 'legacy-v2-80',
    canonicalFamily: 's300',
    productSlug: 'legacy-v2-1084',
    variant: 'legacy base/1084',
  }), '/en/products/s300/legacy-v2-1084?variant=legacy%20base%2F1084');

  assert.equal(catalogSeriesRedirectTarget({
    locale: 'zh',
    requestedFamily: 'legacy-v2-80',
    canonicalFamily: 's300',
    query: '?function=switches&gang=2',
  }), '/zh/products/s300?function=switches&gang=2');

  assert.equal(catalogProductRedirectTarget({
    locale: 'zh',
    requestedFamily: 's300',
    canonicalFamily: 's300',
    productSlug: 'legacy-v2-1084',
  }), null);
});

test('dynamic aliases and branded error shells keep locale-safe navigation', () => {
  const source = (relativePath: string) => readFileSync(new URL(`../${relativePath}`, import.meta.url), 'utf8');
  const guardedFiles = [
    'app/[locale]/products/[code]/[slug]/page.tsx',
    'components/products/ProductMatrixCard.tsx',
    'components/products/VariantViewer.tsx',
    'components/layout/SiteFooter.tsx',
    'app/[locale]/not-found.tsx',
    'app/[locale]/error.tsx',
  ];

  for (const relativePath of guardedFiles) {
    const tags = source(relativePath).match(/<Link\b(?:(?!>).)*>/gs) || [];
    assert.ok(tags.length > 0, `${relativePath} should render at least one localized Link`);
    for (const tag of tags) {
      assert.match(tag, /\blocale=\{locale\}/, `${relativePath} contains an implicit-locale Link: ${tag}`);
    }
  }

  const detailPage = source('app/[locale]/products/[code]/[slug]/page.tsx');
  const seriesPage = source('app/[locale]/products/[code]/page.tsx');
  const localeLayout = source('app/[locale]/layout.tsx');
  const sitemap = source('app/sitemap.ts');
  const footer = source('components/layout/SiteFooter.tsx');
  const notFoundPage = source('app/[locale]/not-found.tsx');
  const catchAllPage = source('app/[locale]/[...rest]/page.tsx');

  assert.match(detailPage, /export const dynamic = 'force-dynamic'/);
  assert.match(localeLayout, /export const dynamic = 'force-dynamic'/);
  assert.match(sitemap, /export const dynamic = 'force-dynamic'/);
  assert.match(catchAllPage, /export const dynamic = 'force-dynamic'/);
  assert.doesNotMatch(detailPage, /getTranslations\(\s*['"`]/);
  assert.doesNotMatch(seriesPage, /getTranslations\(\s*['"`]/);
  assert.doesNotMatch(footer, /getTranslations\(\s*['"`]/);
  assert.doesNotMatch(notFoundPage, /getTranslations/);
  assert.match(notFoundPage, /const locale = useLocale\(\)/);
  assert.doesNotMatch(localeLayout, /generateStaticParams/);
  assert.doesNotMatch(seriesPage, /generateStaticParams/);
  assert.doesNotMatch(detailPage, /generateStaticParams/);
});
