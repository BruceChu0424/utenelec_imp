import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmod, mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PrismaClient } from '@prisma/client';

export const websiteRoot = path.resolve(fileURLToPath(new URL('../..', import.meta.url)));
const prefix = 'uten-website-test-';

export function runNode(script: string, args: string[], environment: Record<string, string | undefined> = {}) {
  const result = spawnSync(process.execPath, [script, ...args], {
    cwd: websiteRoot, encoding: 'utf8', windowsHide: true, timeout: 120_000,
    env: { ...process.env, ...(process.platform === 'win32' ? { RUST_LOG: 'info' } : {}), ...environment },
  });
  assert.equal(result.error, undefined, String(result.error));
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  return result;
}

export function parseLastJsonObject<T>(stdout: string): T {
  const start = Math.max(stdout.lastIndexOf('\n{'), stdout.startsWith('{') ? 0 : -1);
  assert.notEqual(start, -1, `No JSON object found in child output:\n${stdout}`);
  return JSON.parse(stdout.slice(start === 0 ? 0 : start + 1)) as T;
}

export async function migratedDatabase() {
  const temporaryRoot = await mkdtemp(path.join(os.tmpdir(), prefix));
  await chmod(temporaryRoot, 0o700);
  const databasePath = path.join(temporaryRoot, 'catalog.db');
  const databaseUrl = `file:${databasePath.replaceAll('\\', '/')}`;
  const dispose = async () => {
    const resolved = path.resolve(temporaryRoot);
    if (path.dirname(resolved) !== path.resolve(os.tmpdir()) || !path.basename(resolved).startsWith(prefix)) {
      throw new Error(`Refusing unexpected test cleanup: ${resolved}`);
    }
    await rm(resolved, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
  };
  try {
    runNode(path.join(websiteRoot, 'node_modules/prisma/build/index.js'),
      ['migrate', 'deploy', '--schema', 'prisma/schema.prisma'], { DATABASE_URL: databaseUrl });
  } catch (error) {
    await dispose();
    throw error;
  }
  return { temporaryRoot, databasePath, databaseUrl, dispose };
}

type RepairSeries = { id: string; sourceIdentity: string | null; legacySource: string | null; legacyId: string | null;
  rowVersion: number; i18n: string };

/** Nonempty synthetic lineage. No developer DB, real catalog export or media is read. */
export async function seedCatalog(databaseUrl: string, repairs: RepairSeries[] = []) {
  const db = new PrismaClient({ datasources: { db: { url: databaseUrl } } });
  try {
    await db.$transaction(async (tx) => {
      await tx.series.create({ data: { id: 'family', code: 'legacy-80', sourceIdentity: 'ch-uten-v2:series:80',
        legacySource: 'ch-uten-v2', legacyId: '80', i18n: JSON.stringify({ en: { name: 'S300', subtitle: 'keep family' } }),
        published: false } });
      if (repairs.length) {
        for (const row of repairs) {
          assert.ok(row.sourceIdentity && row.legacySource && row.legacyId, 'repair fixture must retain exact source identity');
          await tx.series.create({ data: { ...row, code: `legacy-${row.legacyId}`, parentId: 'family',
            catalogRole: 'COLLECTION', publicSlug: `fixture-${row.legacyId}`, published: true } });
        }
      } else {
        await tx.series.create({ data: { id: 'collection', code: 'legacy-8', sourceIdentity: 'ch-uten-v2:series:8',
          legacySource: 'ch-uten-v2', legacyId: '8', parentId: 'family',
          i18n: JSON.stringify({ en: { name: 'Collection', subtitle: 'retain collection content' } }), published: true } });
        await tx.series.create({ data: { id: 'container', code: 'legacy-60', sourceIdentity: 'ch-uten-v2:series:60',
          legacySource: 'ch-uten-v2', legacyId: '60', i18n: '{"en":{"name":"Container"}}', published: true } });
      }
      await tx.series.create({ data: { id: 'manual', code: 'manual-family', publicSlug: 'manual-family',
        catalogRole: 'FAMILY', i18n: '{"en":{"name":"Manually reviewed family"}}', published: false } });
      const collectionId = repairs.length ? repairs[0].id : 'collection';
      await tx.product.create({ data: { id: 'imported-product', slug: 'imported-switch', seriesId: collectionId,
        sourceIdentity: 'ch-uten-v2:product:501', legacySource: 'ch-uten-v2', legacyId: '501', published: true,
        i18n: JSON.stringify({ en: { name: '2 gang two-way switch', description: 'preserve product content' } }) } });
      await tx.product.create({ data: { id: 'manual-product', slug: 'manual-product', seriesId: 'manual',
        functionType: 'accessories', classificationStatus: 'VERIFIED', published: false,
        i18n: '{"en":{"name":"2 gang switch","description":"verified manual content"}}' } });
      await tx.productVariant.create({ data: { id: 'base-variant', productId: 'imported-product',
        sourceIdentity: 'ch-uten-v2:variant:501:base', legacySource: 'ch-uten-v2', legacyId: '501:base',
        i18n: '{"en":{"name":"Imported base","colorName":"Unknown"}}', dataStatus: 'INFERRED' } });
      await tx.productVariant.create({ data: { id: 'manual-variant', productId: 'manual-product', sku: 'TEST-GOLD',
        sourceIdentity: 'ch-uten-v2:variant:502:gold', i18n: '{"en":{"name":"Reviewed gold"}}',
        dataStatus: 'VERIFIED', isDefault: true, widthMm: 86 } });
      await tx.legacyImportRun.create({ data: { id: 'synthetic-import-run', sourceSystem: 'ch-uten-v2',
        schemaVersion: 'fixture-v1', catalogSha256: 'a'.repeat(64), mediaSha256: 'b'.repeat(64),
        qaReportSha256: 'c'.repeat(64), checkpointSha256: 'd'.repeat(64), bundleSha256: 'e'.repeat(64),
        qaStatus: 'PASS', expectFull: true, inputRoot: 'synthetic-fixture', backupPath: 'synthetic-backup', stats: '{"synthetic":true}' } });
      const sources: Array<readonly [string, string, { seriesId?: string; productId?: string; variantId?: string }]> = [
        ['series', '80', { seriesId: 'family' }],
        ['product', '501', { productId: 'imported-product' }],
        ['variant', '501:base', { variantId: 'base-variant' }],
        ...repairs.map((row) => ['series', row.legacyId!, { seriesId: row.id }] as const),
      ];
      for (const [entityType, sourceId, refs] of sources) {
        await tx.legacySourceRecord.create({ data: { importRunId: 'synthetic-import-run', sourceSystem: 'ch-uten-v2',
          entityType, sourceId, locale: 'en', identityKey: `ch-uten-v2:${entityType}:${sourceId}`, sourceUrl: 'https://example.invalid/fixture',
          sourceHash: 'f'.repeat(64), rawPayload: '{"original":"preserve audit bytes"}', publishable: false, ...refs } });
      }
    }, { timeout: 30_000 });
  } finally { await db.$disconnect(); }
}
