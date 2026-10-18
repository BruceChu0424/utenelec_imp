import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { PrismaClient as SqliteClient } from '@prisma/client';
import { websiteMigrationTables } from '../scripts/migration-contract.mjs';
import { migratedDatabase, parseLastJsonObject, websiteRoot } from './helpers/migrated-database';
import { createIsolatedPostgresqlDatabase, postgresqlTestsEnabled } from './helpers/isolated-postgresql';

type MigrationReport = {
  mode: 'dry-run' | 'applied';
  emptyTarget?: boolean;
  readbackVerified?: boolean;
  tables: Record<string, { count: number; sha256: string }>;
};

const familyFixture = {
  id: 'fixture-series-media-family',
  code: 'fixture-series-media-family',
  publicSlug: 'fixture-series-media-family-public',
  catalogRole: 'FAMILY',
  rowVersion: 7,
  i18n: JSON.stringify({
    zh: { name: '迁移测试系列', subtitle: '保留系列图册', description: '仅用于隔离数据库测试。' },
    en: { name: 'Migration fixture family', subtitle: 'Preserve the gallery', description: 'Isolated database test only.' },
  }),
  coverImage: '/uploads/series/fixture-family-cover.webp',
  sortOrder: 19,
  published: true,
  sourceIdentity: 'fixture:postgresql-series-media:family',
  legacySource: 'synthetic-migration-fixture',
  legacyId: 'family-stable-source-id',
  parentId: null,
  createdAt: new Date('2024-02-29T08:09:10.123Z'),
  updatedAt: new Date('2025-06-01T12:34:56.789Z'),
};

const mediaFixture = {
  id: 'fixture-series-media-combination',
  seriesId: familyFixture.id,
  role: 'combination',
  image: '/uploads/series/fixture-combination-86.webp',
  i18n: JSON.stringify({
    zh: { title: '系列组合图', alt: '白色面板与银色边框', description: '图册说明第一行\n图册说明第二行' },
    en: { title: 'Family combination', alt: 'White panel and silver frame', description: 'Preserve accents: café.' },
  }),
  sortOrder: 37,
  // A false value detects accidental re-creation with the published=true default.
  published: false,
  createdAt: new Date('2024-03-01T01:02:03.456Z'),
  updatedAt: new Date('2025-07-02T04:05:06.987Z'),
};

async function fileSha256(file: string) {
  return createHash('sha256').update(await readFile(file)).digest('hex');
}

test('SQLite to PostgreSQL preserves a nonempty series gallery and refuses to merge it twice', {
  skip: !postgresqlTestsEnabled(),
  timeout: 240_000,
}, async (t) => {
  const source = await migratedDatabase();
  const sqlite = new SqliteClient({ datasources: { db: { url: source.databaseUrl } } });
  let target: Awaited<ReturnType<typeof createIsolatedPostgresqlDatabase>> | undefined;
  let evidence: Record<string, unknown> | undefined;
  try {
    const expected = await sqlite.$transaction(async (tx) => {
      const family = await tx.series.create({ data: familyFixture });
      const media = await tx.seriesMedia.create({ data: mediaFixture });
      return { family, media };
    });
    assert.deepEqual(expected, { family: familyFixture, media: mediaFixture });
    assert.equal(await sqlite.series.count(), 1);
    assert.equal(await sqlite.seriesMedia.count(), 1);
    // Close every source connection before handing the offline SQLite file to the migrator.
    await sqlite.$disconnect();
    const sourceSha256 = await fileSha256(source.databasePath);

    target = await createIsolatedPostgresqlDatabase('series_media');
    assert.match(target.databaseName, /^uten_website_cms_test_[a-z0-9_]+$/);
    const script = path.join(websiteRoot, 'scripts/migrate-sqlite-to-postgresql.mjs');
    const sourceArgs = ['--source', source.databasePath];
    const dryRun = target.runNode(script, sourceArgs);
    assert.equal(dryRun.status, 0, dryRun.stderr);
    const dryReport = parseLastJsonObject<MigrationReport>(dryRun.stdout);
    assert.equal(dryReport.mode, 'dry-run');
    assert.equal(dryReport.emptyTarget, true);
    assert.deepEqual(Object.keys(dryReport.tables).sort(), [...websiteMigrationTables].sort());
    for (const [table, result] of Object.entries(dryReport.tables)) {
      const expectedCount = ['websiteStateAuthority', 'series', 'seriesMedia'].includes(table) ? 1 : 0;
      assert.equal(result.count, expectedCount, `${table} source count`);
      assert.match(result.sha256, /^[0-9a-f]{64}$/);
    }
    assert.equal(await target.client.series.count(), 0, 'dry-run must leave the target empty');
    assert.equal(await target.client.seriesMedia.count(), 0, 'dry-run must not insert gallery entries');
    assert.equal(await target.client.websiteStateAuthority.count(), 0);

    const applyArgs = [...sourceArgs, '--apply', '--confirm', 'WEBSITE_POSTGRESQL_MIGRATION'];
    const applied = target.runNode(script, applyArgs);
    assert.equal(applied.status, 0, applied.stderr);
    const appliedReport = parseLastJsonObject<MigrationReport>(applied.stdout);
    assert.equal(appliedReport.mode, 'applied');
    assert.equal(appliedReport.readbackVerified, true);
    assert.deepEqual(appliedReport.tables, dryReport.tables, 'every migrated table must retain its count and hash');

    const familyWithMedia = await target.client.series.findUniqueOrThrow({
      where: { id: familyFixture.id }, include: { media: { orderBy: { id: 'asc' } } },
    });
    const { media: gallery, ...family } = familyWithMedia;
    assert.deepEqual(family, expected.family, 'all family fields and its stable source identity must survive');
    assert.deepEqual(gallery, [expected.media], 'the family must retain its original complete gallery record');
    const mediaWithFamily = await target.client.seriesMedia.findUniqueOrThrow({
      where: { id: mediaFixture.id }, include: { series: true },
    });
    const { series: linkedFamily, ...media } = mediaWithFamily;
    assert.deepEqual(media, expected.media, 'image, i18n, role, order, unpublished state, IDs and timestamps must survive');
    assert.deepEqual(linkedFamily, expected.family, 'the reverse series relation must retain the exact family');
    assert.equal(await target.client.series.count(), 1);
    assert.equal(await target.client.seriesMedia.count(), 1);
    assert.equal(await fileSha256(source.databasePath), sourceSha256, 'migration must not mutate the offline source');

    const repeated = target.runNode(script, applyArgs);
    assert.notEqual(repeated.status, 0, 'replaying into a populated target must fail');
    assert.match(repeated.stderr, /Destination has application records; refusing to merge or overwrite/);
    assert.deepEqual(await target.client.series.findMany(), [expected.family]);
    assert.deepEqual(await target.client.seriesMedia.findMany(), [expected.media]);
    assert.equal(await fileSha256(source.databasePath), sourceSha256, 'refused replay must also leave the source intact');

    evidence = {
      status: 'PASS',
      databaseName: target.databaseName,
      source: 'new temporary SQLite fixture; no developer or runtime database read',
      sourceSha256,
      sourceUnchanged: true,
      dryRunKeptTargetEmpty: true,
      readbackVerified: appliedReport.readbackVerified,
      tables: appliedReport.tables,
      series: family,
      seriesMedia: media,
      bidirectionalRelationVerified: true,
      populatedTargetReplayRefused: true,
      scope: 'database records and image paths; does not copy or claim verification of image file bytes',
    };
  } finally {
    try {
      await target?.dispose();
    } finally {
      await sqlite.$disconnect();
      await source.dispose();
    }
  }

  assert.ok(evidence);
  const evidenceDirectory = path.join(websiteRoot, '..', '.local-artifacts/website-imp/postgresql-tests');
  await mkdir(evidenceDirectory, { recursive: true });
  const evidencePath = path.join(evidenceDirectory, `series-media-${evidence.databaseName}.json`);
  await writeFile(evidencePath, JSON.stringify({ ...evidence, isolatedTargetDisposed: true }, null, 2) + '\n');
  t.diagnostic(`SeriesMedia migration readback and isolated cleanup PASS; evidence: ${evidencePath}`);
});
