import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdir, mkdtemp, readFile, readdir, rm, unlink, writeFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';
import { PrismaClient } from '@prisma/client';
import {
  SOURCE_SCHEMA_VERSION,
  applyLegacyV2,
  applyPreparedImportForTest,
  dryRunLegacyV2,
  prepareLegacyV2Input,
} from '../scripts/lib/legacy-v2-importer';

const WEBSITE_ROOT = path.resolve(__dirname, '..');
const FIXTURE_DIRECTORY_PREFIX = '.tmp-legacy-import-test-';
const FIXTURE_DIRECTORY_PATTERN = /^\.tmp-legacy-import-test-[A-Za-z0-9]{6}$/;
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  'base64',
);
const PNG_TWO = Buffer.concat([PNG, Buffer.from([0x00])]);

function digest(value: Buffer | string): string {
  return createHash('sha256').update(value).digest('hex');
}

async function writeJson(filename: string, value: unknown): Promise<void> {
  await mkdir(path.dirname(filename), { recursive: true });
  await writeFile(filename, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

async function writeSyntheticFixture(root: string): Promise<void> {
  const mediaHash = digest(PNG);
  const secondMediaHash = digest(PNG_TWO);
  const mediaRelative = `media/${mediaHash.slice(0, 2)}/${mediaHash}.png`;
  const secondMediaRelative = `media/${secondMediaHash.slice(0, 2)}/${secondMediaHash}.png`;
  await mkdir(path.dirname(path.join(root, mediaRelative)), { recursive: true });
  await mkdir(path.dirname(path.join(root, secondMediaRelative)), { recursive: true });
  await Promise.all([
    writeFile(path.join(root, mediaRelative), PNG),
    writeFile(path.join(root, secondMediaRelative), PNG_TWO),
  ]);
  const now = '2026-08-09T00:00:00.000Z';

  async function provenance(locale: 'zh' | 'en', kind: string, id: string, sourceUrl: string) {
    const html = Buffer.from(`<html><body>${locale}:${kind}:${id}</body></html>`, 'utf8');
    const sourceHash = digest(html);
    const rawHtmlPath = `raw/html/${locale}/${kind}/${sourceHash}.html`;
    await mkdir(path.dirname(path.join(root, rawHtmlPath)), { recursive: true });
    await writeFile(path.join(root, rawHtmlPath), html);
    return { sourceUrl, finalUrl: sourceUrl, scrapedAt: now, sourceHash, rawHtmlPath, httpStatus: 200 };
  }

  const categoryInputs = [
    ['zh', '1', null, '墙壁开关'],
    ['zh', '8', '1', '大跷板&…'],
    ['zh', '2', null, '插座'],
    ['zh', '23', '2', '大跷板&…'],
    ['en', '1', null, 'Wall switches'],
    ['en', '8', '1', 'Rocker Switch Series'],
  ] as const;
  const categories = [];
  for (const [locale, sortId, parentSortId, name] of categoryInputs) {
    categories.push({
      identityKey: `${locale}:${sortId}`,
      locale,
      sortId,
      parentSortId,
      sortPath: parentSortId ? `0,${parentSortId},${sortId},` : `0,${sortId},`,
      name,
      inferred: false,
      ...(await provenance(locale, 'product-list', `category-${sortId}`, `http://www.ch-uten.com/${locale === 'en' ? 'en/' : ''}Product.asp`)),
    });
  }

  const productInputs = [
    ['zh', '1', '8', '101', 'GK11', '安全的中文说明'],
    ['zh', '124', '23', '201', 'GK11', '同名但不同旧站 ID'],
    ['en', '1', '8', '101', 'GK11 switch', 'Safe English description'],
  ] as const;
  const products = [];
  for (const [locale, oldSiteId, sortId, sequence, name, descriptionText] of productInputs) {
    const sourceUrl = `http://www.ch-uten.com/${locale === 'en' ? 'en/' : ''}productshow.asp?ID=${oldSiteId}&SortID=${sortId}`;
    products.push({
      identityKey: `${locale}:${oldSiteId}`,
      locale,
      oldSiteId,
      sortId,
      sortPath: `0,${sortId},`,
      sequence,
      name,
      listingName: name,
      authoritativeName: name,
      detailStatus: 'ok',
      descriptionText,
      descriptionHtml: `<script>alert('legacy')</script><p>${descriptionText}</p>`,
      descriptionHtmlSafety: 'UNTRUSTED_LEGACY_HTML_DO_NOT_RENDER',
      thumbnailSourceUrl: 'http://www.ch-uten.com/Upload/PicFiles/shared.png',
      mainImageSourceUrl: 'http://www.ch-uten.com/Upload/PicFiles/shared.png',
      thumbnailSha256: mediaHash,
      mainImageSha256: mediaHash,
      mediaSha256: [mediaHash],
      assetUrls: ['http://www.ch-uten.com/Upload/PicFiles/shared.png'],
      price: { status: 'UNSET', amount: null, currency: null, publicationApproved: false },
      ...(await provenance(locale, 'product-detail', oldSiteId, sourceUrl)),
    });
  }

  const newsUrl = 'http://www.ch-uten.com/newsshow.asp?ID=10';
  const news = [{
    identityKey: 'zh:10', locale: 'zh', oldSiteId: '10', title: '旧站新闻', assetUrls: [],
    ...(await provenance('zh', 'news-detail', '10', newsUrl)),
  }];
  const pageUrl = 'http://www.ch-uten.com/about.asp?id=1';
  const pages = [{
    key: 'about-1', identityKey: 'zh:about-1', locale: 'zh', title: '关于我们', assetSourceUrls: [],
    ...(await provenance('zh', 'static', 'about-1', pageUrl)),
  }];
  const catalog = {
    schemaVersion: SOURCE_SCHEMA_VERSION,
    generatedAt: now,
    sourceBaseUrl: 'http://www.ch-uten.com/',
    baseline: {},
    scope: {
      locales: ['zh', 'en'],
      fullRequested: false,
      downloadMedia: true,
      concurrency: 2,
      progress: {
        zh: { productRequested: 1, productCompleted: 1, detailRequested: 2, detailCompleted: 2 },
        en: { productRequested: 1, productCompleted: 1, detailRequested: 1, detailCompleted: 1 },
      },
    },
    categories,
    products,
    news,
    pages,
  };
  const media = {
    schemaVersion: SOURCE_SCHEMA_VERSION,
    generatedAt: now,
    sourceBaseUrl: 'http://www.ch-uten.com/',
    assets: [
      {
        sha256: mediaHash,
        mimeType: 'image/png',
        extension: '.png',
        bytes: PNG.length,
        width: 1,
        height: 1,
        localPath: mediaRelative,
        scrapedAt: now,
        sourceUrls: ['http://www.ch-uten.com/Upload/PicFiles/shared.png'],
        sourceRefs: ['product:zh:1:main', 'product:zh:124:main', 'product:en:1:main'],
      },
      {
        sha256: secondMediaHash,
        mimeType: 'image/png',
        extension: '.png',
        bytes: PNG_TWO.length,
        width: 1,
        height: 1,
        localPath: secondMediaRelative,
        scrapedAt: now,
        sourceUrls: ['http://www.ch-uten.com/Upload/PicFiles/secondary.png'],
        sourceRefs: ['page:zh:about-1'],
      },
    ],
    failures: [],
  };
  const qa = {
    schemaVersion: SOURCE_SCHEMA_VERSION,
    generatedAt: now,
    status: 'pass',
    expectFull: false,
    checks: [{ id: 'prices-remain-unset', status: 'pass', severity: 'error' }],
    fetchErrors: [],
    parseErrors: [],
    conflicts: [],
    summary: { products: { zh: 2, en: 1 } },
  };
  const checkpoint = {
    checkpointVersion: 1,
    baseUrl: 'http://www.ch-uten.com/',
    createdAt: now,
    updatedAt: now,
    pages: {
      [String(products[0].sourceUrl)]: { ...products[0], status: 'ok' },
    },
    media: {
      'http://www.ch-uten.com/Upload/PicFiles/shared.png': {
        status: 'ok',
        sourceUrl: 'http://www.ch-uten.com/Upload/PicFiles/shared.png',
        finalUrl: 'http://www.ch-uten.com/Upload/PicFiles/shared.png',
        sha256: mediaHash,
        localPath: mediaRelative,
        bytes: PNG.length,
        mimeType: 'image/png',
        extension: '.png',
        width: 1,
        height: 1,
        scrapedAt: now,
      },
      'http://www.ch-uten.com/Upload/PicFiles/secondary.png': {
        status: 'ok',
        sourceUrl: 'http://www.ch-uten.com/Upload/PicFiles/secondary.png',
        finalUrl: 'http://www.ch-uten.com/Upload/PicFiles/secondary.png',
        sha256: secondMediaHash,
        localPath: secondMediaRelative,
        bytes: PNG_TWO.length,
        mimeType: 'image/png',
        extension: '.png',
        width: 1,
        height: 1,
        scrapedAt: now,
      },
    },
    refusedUrls: [],
    diagnostics: { fetchErrors: [], parseErrors: [], conflicts: [] },
  };
  await Promise.all([
    writeJson(path.join(root, 'catalog.json'), catalog),
    writeJson(path.join(root, 'media.json'), media),
    writeJson(path.join(root, 'qa-report.json'), qa),
    writeJson(path.join(root, 'checkpoint.json'), checkpoint),
  ]);
}

function databaseUrl(filename: string): string {
  return `file:${path.resolve(filename).replaceAll('\\', '/')}`;
}

async function withFixture(run: (root: string) => Promise<void>): Promise<void> {
  // Keep Prisma's temporary SQLite file inside the workspace; some Windows
  // sandbox profiles do not let the schema engine create databases in %TEMP%.
  const root = await mkdtemp(path.join(WEBSITE_ROOT, FIXTURE_DIRECTORY_PREFIX));
  try {
    await writeSyntheticFixture(root);
    await run(root);
  } finally {
    await removeFixtureDirectory(root);
  }
}

async function removeFixtureDirectory(root: string): Promise<void> {
  const exactRoot = path.resolve(root);
  if (
    path.dirname(exactRoot) !== WEBSITE_ROOT
    || !FIXTURE_DIRECTORY_PATTERN.test(path.basename(exactRoot))
  ) {
    throw new Error(`Refusing to clean a non-fixture directory: ${exactRoot}`);
  }

  const retryableCodes = new Set(['EACCES', 'EBUSY', 'ENOTEMPTY', 'EPERM']);
  const attempts = 8;
  // Prisma disconnect is awaited at every call site. A short settle plus bounded
  // exponential backoff handles Windows/AV releasing the SQLite handle slightly later.
  await delay(25);
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    try {
      await rm(exactRoot, { recursive: true, force: true });
      return;
    } catch (error) {
      const code = error && typeof error === 'object' && 'code' in error
        ? String(error.code)
        : '';
      if (!retryableCodes.has(code) || attempt === attempts - 1) throw error;
      await delay(50 * (2 ** attempt));
    }
  }
}

test('dry-run preserves stable ID identity and blocks partial output from apply', async () => {
  await withFixture(async (root) => {
    const report = path.join(root, 'import-plan.json');
    const plan = await dryRunLegacyV2(root, report);
    assert.equal(plan.status, 'pass');
    assert.equal(plan.applyGate.eligible, false);
    assert.match(plan.applyGate.reasons.join(' '), /expectFull is false/);
    assert.equal(plan.summary.localizedProductRecords, 3);
    assert.equal(plan.summary.canonicalProducts, 2);
    assert.equal(plan.summary.bilingualProducts, 1);
    assert.equal(plan.summary.duplicateNameGroupsPreserved, 1);
    assert.equal(plan.summary.variants, 2);
    const neverDatabase = path.join(root, 'must-not-be-created.db');
    await assert.rejects(
      applyLegacyV2({
        inputRoot: root,
        planPath: report,
        databasePath: neverDatabase,
        publicDir: path.join(root, 'public-never'),
      }),
      /not eligible for apply/,
    );
    assert.equal(existsSync(neverDatabase), false);
    assert.equal(existsSync(path.join(root, 'public-never')), false);

    const mediaFilename = path.join(root, 'media.json');
    const mixedOriginMedia = JSON.parse(await readFile(mediaFilename, 'utf8')) as {
      assets: Array<{ sourceUrls: string[] }>;
    };
    mixedOriginMedia.assets[0].sourceUrls[0] = 'http://127.0.0.1:8999/Upload/PicFiles/shared.png';
    await writeJson(mediaFilename, mixedOriginMedia);
    await assert.rejects(
      prepareLegacyV2Input(root),
      /same origin as catalog\.sourceBaseUrl/,
      'a production catalog may not mix loopback source/media URLs',
    );
  });
});

test('fixture transaction on an isolated SQLite database uses backup, unpublished rows and hashed public media', async () => {
  await withFixture(async (root) => {
    // Create the schema only inside this fixture. The real CMS database may be
    // populated and open by the running site, and must never affect this test.
    const databasePath = path.join(root, 'legacy-import-test.db');
    const publicDir = path.join(root, 'public');
    const backupDir = path.join(root, 'backups');
    const prismaCli = path.join(WEBSITE_ROOT, 'node_modules', 'prisma', 'build', 'index.js');
    let schemaPushError: unknown;
    for (let attempt = 0; attempt < 2; attempt += 1) {
      try {
        execFileSync(process.execPath, [prismaCli, 'db', 'push', '--skip-generate', '--accept-data-loss'], {
          cwd: WEBSITE_ROOT,
          env: {
            ...process.env,
            DATABASE_URL: databaseUrl(databasePath),
            RUST_BACKTRACE: '1',
            RUST_LOG: 'info',
          },
          stdio: 'pipe',
        });
        schemaPushError = undefined;
        break;
      } catch (error) {
        schemaPushError = error;
      }
    }
    if (schemaPushError) throw schemaPushError;

    const before = new PrismaClient({ datasources: { db: { url: databaseUrl(databasePath) } } });
    let originalProductCount: number;
    try {
      originalProductCount = await before.product.count();
      assert.equal(originalProductCount, 0, 'the test database starts isolated from the real CMS database');
      await before.product.create({
        data: {
          slug: 'manual-gk11',
          i18n: JSON.stringify({ zh: { name: 'GK11', description: '人工内容' } }),
          published: true,
        },
      });
      await before.product.create({
        data: {
          slug: 'legacy-v2-124',
          i18n: JSON.stringify({ zh: { name: '阻断冲突', description: '验证事务回滚' } }),
          published: false,
        },
      });
    } finally {
      await before.$disconnect();
    }

    const prepared = await prepareLegacyV2Input(root);
    const runTestApply = async () => {
      const previousNodeEnv = process.env.NODE_ENV;
      const mutableEnvironment = process.env as Record<string, string | undefined>;
      mutableEnvironment.NODE_ENV = 'test';
      try {
        return await applyPreparedImportForTest(prepared, { databasePath, publicDir, backupDir });
      } finally {
        if (previousNodeEnv === undefined) delete mutableEnvironment.NODE_ENV;
        else mutableEnvironment.NODE_ENV = previousNodeEnv;
      }
    };

    const changedMedia = prepared.media.find((item) => item.bytes === PNG_TWO.length);
    assert.ok(changedMedia);
    await writeFile(changedMedia.absoluteSourcePath, Buffer.from('changed after prepare', 'utf8'));
    await assert.rejects(runTestApply(), /changed after dry-run/, 'copy re-hashes bytes after prepare');
    for (const item of prepared.media.filter((media) => media.publicPath)) {
      const destination = path.join(publicDir, (item.publicPath ?? '').replace(/^\//, '').split('/').join(path.sep));
      assert.equal(existsSync(destination), false, 'a multi-worker copy failure cleans every newly published hash');
    }
    const afterFailedCopy = existsSync(publicDir) ? await readdir(publicDir, { recursive: true }) : [];
    assert.ok(afterFailedCopy.every((entry) => !String(entry).endsWith('.tmp')), 'failed copies leave no staging file');
    await writeFile(changedMedia.absoluteSourcePath, PNG_TWO);

    await assert.rejects(
      runTestApply(),
      /transaction rolled back.*non-matching record/i,
    );
    const afterRollback = new PrismaClient({ datasources: { db: { url: databaseUrl(databasePath) } } });
    try {
      assert.equal(await afterRollback.legacyImportRun.count(), 0);
      assert.equal(await afterRollback.product.count({ where: { legacySource: 'ch-uten-v2' } }), 0);
      await afterRollback.product.delete({ where: { slug: 'legacy-v2-124' } });
    } finally {
      await afterRollback.$disconnect();
    }
    for (const item of prepared.media.filter((media) => media.publicPath)) {
      const destination = path.join(publicDir, (item.publicPath ?? '').replace(/^\//, '').split('/').join(path.sep));
      assert.equal(existsSync(destination), false, 'transaction rollback cleans only this locked import\'s new media');
    }
    const result = await runTestApply();
    assert.equal(result.status, 'applied');
    assert.equal(result.copiedMedia, 2);
    assert.equal(existsSync(result.backupPath), true);
    assert.equal((await readdir(backupDir)).length, 3, 'every failed/successful apply attempt retains a backup');

    const client = new PrismaClient({ datasources: { db: { url: databaseUrl(databasePath) } } });
    try {
      const allProducts = await client.product.findMany({ include: { variants: true } });
      assert.equal(allProducts.length, originalProductCount + 3, 'manual same-name row must not be merged');
      const imported = allProducts.filter((item) => item.legacySource === 'ch-uten-v2');
      assert.equal(imported.length, 2);
      assert.deepEqual(imported.map((item) => item.legacyId).sort(), ['1', '124']);
      assert.ok(imported.every((item) => item.published === false));
      assert.ok(imported.every((item) => item.variants.length === 1 && item.variants[0].published === false));
      const bilingual = imported.find((item) => item.legacyId === '1');
      assert.ok(bilingual);
      const i18n = JSON.parse(bilingual.i18n) as Record<string, { name: string; description: string }>;
      assert.equal(i18n.zh.name, 'GK11');
      assert.equal(i18n.en.name, 'GK11 switch');
      assert.doesNotMatch(bilingual.i18n, /<script/i);

      const rockerSeries = await client.series.findUniqueOrThrow({
        where: { sourceIdentity: 'ch-uten-v2:series:8' },
      });
      const rockerI18n = JSON.parse(rockerSeries.i18n) as Record<string, { name: string }>;
      assert.equal(rockerI18n.zh.name, '大跷板开关系列');
      assert.equal(rockerI18n.en.name, 'Rocker Switches');

      const records = await client.legacySourceRecord.findMany();
      assert.equal(records.length, 11);
      assert.ok(records.every((item) => item.publishable === false));
      assert.ok(records.some((item) => /<script/i.test(item.rawPayload)), 'raw HTML remains isolated audit evidence');
      const rawRockerSeries = records.find((item) => (
        item.entityType === 'series' && item.sourceId === '8' && item.locale === 'zh'
      ));
      assert.ok(rawRockerSeries);
      assert.match(rawRockerSeries.rawPayload, /大跷板&…/u, 'source label remains immutable audit evidence');
      const assets = await client.legacyMediaAsset.findMany();
      assert.equal(assets.length, 2);
      const asset = assets[0];
      assert.match(asset.publicPath ?? '', /^\/uploads\/legacy-v2\/[a-f0-9]{2}\/[a-f0-9]{64}\.png$/);
      const publicFile = path.join(publicDir, (asset.publicPath ?? '').replace(/^\//, '').split('/').join(path.sep));
      assert.equal(digest(await readFile(publicFile)), asset.sha256);
      assert.ok((await client.productMedia.count()) >= 6);
      assert.equal(await client.legacyImportRun.count(), 1);

      await unlink(publicFile);
      const repaired = await runTestApply();
      assert.equal(repaired.status, 'already-applied');
      assert.equal(repaired.copiedMedia, 1, 'idempotent apply repairs a missing content-addressed public file');
      assert.equal(digest(await readFile(publicFile)), asset.sha256);

      const originalBundle = prepared.plan.digests.bundleSha256;
      const importedSeries = await client.series.findFirstOrThrow({ where: { legacySource: 'ch-uten-v2' } });
      await client.series.update({ where: { id: importedSeries.id }, data: { legacySource: 'conflicting-source' } });
      prepared.plan.digests.bundleSha256 = digest('series-identity-conflict');
      await assert.rejects(runTestApply(), /Series .*conflicting legacySource/);
      await client.series.update({ where: { id: importedSeries.id }, data: { legacySource: 'ch-uten-v2' } });

      const importedProduct = await client.product.findFirstOrThrow({ where: { legacySource: 'ch-uten-v2' } });
      const originalProductLegacyId = importedProduct.legacyId;
      await client.product.update({ where: { id: importedProduct.id }, data: { legacyId: 'conflicting-id' } });
      prepared.plan.digests.bundleSha256 = digest('product-identity-conflict');
      await assert.rejects(runTestApply(), /Product .*conflicting legacyId/);
      await client.product.update({ where: { id: importedProduct.id }, data: { legacyId: originalProductLegacyId } });

      const importedVariant = await client.productVariant.findFirstOrThrow({ where: { legacySource: 'ch-uten-v2' } });
      await client.productVariant.update({ where: { id: importedVariant.id }, data: { legacySource: 'conflicting-source' } });
      prepared.plan.digests.bundleSha256 = digest('variant-identity-conflict');
      await assert.rejects(runTestApply(), /Variant .*conflicting legacySource/);
      await client.productVariant.update({ where: { id: importedVariant.id }, data: { legacySource: 'ch-uten-v2' } });
      prepared.plan.digests.bundleSha256 = originalBundle;
      assert.equal(await client.legacyImportRun.count(), 1, 'identity conflicts roll back their import run');
      assert.equal((await readdir(backupDir)).length, 7, 'all guarded attempts retain independent SQLite backups');
    } finally {
      await client.$disconnect();
    }
  });
});
