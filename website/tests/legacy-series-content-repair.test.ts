import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { copyFile, mkdtemp, readFile, rm } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  buildLegacySeriesContentPlan,
  LEGACY_SERIES_CONTENT_REPAIRS,
  LEGACY_SOURCE_SYSTEM,
  type LegacySeriesContentSnapshot,
} from '../scripts/lib/legacy-series-content';

const WEBSITE_ROOT = path.resolve(fileURLToPath(new URL('..', import.meta.url)));
const TEMPORARY_PREFIX = '.legacy-series-content-test-';
const TEMPORARY_PATTERN = /^\.legacy-series-content-test-[A-Za-z0-9]{6}$/u;

type CatalogCategory = {
  locale: 'zh' | 'en';
  sortId: string;
  name?: string | null;
};

type CatalogProduct = {
  locale: 'zh' | 'en';
  oldSiteId: string;
  sortPath: string;
  rawHtmlPath: string;
};

function firstNonTargetSourceName(
  allowed: readonly (string | null)[],
  target: string,
): string | null {
  return allowed.find((name) => name !== target) ?? target;
}

function fixtureRows(): LegacySeriesContentSnapshot[] {
  return LEGACY_SERIES_CONTENT_REPAIRS.map((repair, index) => ({
    id: `series-${repair.sourceId}`,
    sourceIdentity: repair.sourceIdentity,
    legacySource: LEGACY_SOURCE_SYSTEM,
    legacyId: repair.sourceId,
    rowVersion: index + 1,
    i18n: JSON.stringify({
      zh: {
        name: firstNonTargetSourceName(repair.allowedSourceNames.zh, repair.publicNames.zh),
        subtitle: `保留-${repair.sourceId}`,
      },
      ...(firstNonTargetSourceName(repair.allowedSourceNames.en, repair.publicNames.en) === null
        ? {}
        : {
            en: {
              name: firstNonTargetSourceName(repair.allowedSourceNames.en, repair.publicNames.en),
              subtitle: `keep-${repair.sourceId}`,
            },
          }),
      de: { name: `Unchanged ${repair.sourceId}` },
    }),
  }));
}

function sha256(value: Buffer | string): string {
  return createHash('sha256').update(value).digest('hex');
}

function htmlBreadcrumb(html: string, sortPath: string): Array<{ sortId: string; name: string }> {
  const match = html.match(/<div\s+class=["']rtop["'][^>]*>([\s\S]*?)<\/div>/iu);
  assert.ok(match, 'detail evidence must contain div.rtop');
  const text = match[1]
    .replace(/<[^>]+>/gu, ' ')
    .replace(/&nbsp;/giu, ' ')
    .replace(/&amp;/giu, '&')
    .replace(/&#0*38;/giu, '&')
    .replace(/\s+/gu, ' ')
    .trim();
  const ids = sortPath.split(',').filter((part) => part && part !== '0');
  const segments = text.split('|').map((part) => part.trim()).filter(Boolean);
  assert.ok(segments.length >= ids.length, `${sortPath} cannot align to ${text}`);
  const names = segments.slice(-ids.length);
  return ids.map((sortId, index) => ({ sortId, name: names[index] }));
}

test('reviewed repair manifest covers the exact 50 imported Series anomalies', () => {
  assert.equal(LEGACY_SERIES_CONTENT_REPAIRS.length, 50);
  assert.equal(new Set(LEGACY_SERIES_CONTENT_REPAIRS.map((item) => item.sourceId)).size, 50);
  assert.deepEqual(
    LEGACY_SERIES_CONTENT_REPAIRS.map((item) => Number.parseInt(item.sourceId, 10)).sort((a, b) => a - b),
    [
      8, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
      32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50,
      51, 52, 53, 55, 56, 57, 58, 59, 60, 71, 73,
    ],
  );
  for (const repair of LEGACY_SERIES_CONTENT_REPAIRS) {
    assert.equal(repair.sourceIdentity, `${LEGACY_SOURCE_SYSTEM}:series:${repair.sourceId}`);
    assert.doesNotMatch(repair.publicNames.zh, /[…�ঀ]/u);
    assert.doesNotMatch(repair.publicNames.en, /Mirco|Electroic|swotcj|spclet|siwtch/iu);
  }
});

test('plan repairs only reviewed source names and preserves unrelated localized fields', () => {
  const plan = buildLegacySeriesContentPlan(fixtureRows());
  assert.deepEqual(plan.issues, []);
  assert.equal(plan.updates.length, 50);
  assert.equal(plan.summary.expectedSeries, 50);
  assert.equal(plan.summary.locatedSeries, 50);

  for (const update of plan.updates) {
    const parsed = JSON.parse(update.i18n) as Record<string, Record<string, string>>;
    assert.equal(parsed.zh.name, update.after.zh);
    assert.equal(parsed.en.name, update.after.en);
    assert.equal(parsed.zh.subtitle, `保留-${update.sourceId}`);
    assert.equal(parsed.de.name, `Unchanged ${update.sourceId}`);
  }

  const unknown = fixtureRows();
  const first = unknown[0];
  unknown[0] = {
    ...first,
    i18n: JSON.stringify({ zh: { name: '人工审核后的自定义名称' }, en: { name: 'Custom reviewed name' } }),
  };
  const refused = buildLegacySeriesContentPlan(unknown);
  assert.equal(refused.updates.length, 49);
  assert.equal(refused.issues.length, 1);
  assert.match(refused.issues[0], /refusing to overwrite/u);
});

test('raw detail breadcrumbs reconstruct all 50 Chinese names without conflicts', { timeout: 30_000 }, async (t) => {
  const outputRoot = path.join(WEBSITE_ROOT, '.scrape', 'v2', 'output');
  const catalogPath = path.join(outputRoot, 'catalog.json');
  if (!existsSync(catalogPath)) {
    t.skip('full legacy-v2 evidence bundle is not present');
    return;
  }
  const catalog = JSON.parse(await readFile(catalogPath, 'utf8')) as {
    categories: CatalogCategory[];
    products: CatalogProduct[];
  };
  const categories = new Map(catalog.categories.map((item) => [`${item.locale}:${item.sortId}`, item]));
  const anomalyCategories = catalog.categories.filter((item) => (
    item.locale === 'zh' && /[…�ঀ]/u.test(item.name ?? '')
  ));
  assert.equal(anomalyCategories.length, 50);

  const namesByIdentity = new Map<string, Set<string>>();
  for (const product of catalog.products) {
    const html = await readFile(path.join(outputRoot, product.rawHtmlPath), 'utf8');
    for (const item of htmlBreadcrumb(html, product.sortPath)) {
      const key = `${product.locale}:${item.sortId}`;
      const names = namesByIdentity.get(key) ?? new Set<string>();
      names.add(item.name);
      namesByIdentity.set(key, names);
    }
  }
  assert.equal(namesByIdentity.size, catalog.categories.length, 'every localized category needs detail evidence');
  for (const category of catalog.categories) {
    const names = namesByIdentity.get(`${category.locale}:${category.sortId}`);
    assert.equal(names?.size, 1, `conflicting/missing breadcrumb for ${category.locale}:${category.sortId}`);
  }

  for (const repair of LEGACY_SERIES_CONTENT_REPAIRS) {
    const zhCategory = categories.get(`zh:${repair.sourceId}`);
    assert.ok(zhCategory, `missing zh category ${repair.sourceId}`);
    assert.ok(repair.allowedSourceNames.zh.includes(zhCategory.name ?? null));
    assert.deepEqual(
      [...(namesByIdentity.get(`zh:${repair.sourceId}`) ?? [])],
      [repair.publicNames.zh],
      `conflicting/missing zh breadcrumb evidence for ${repair.sourceIdentity}`,
    );
    const englishNames = [...(namesByIdentity.get(`en:${repair.sourceId}`) ?? [])];
    assert.ok(
      englishNames.every((name) => repair.allowedSourceNames.en.includes(name)),
      `unexpected English source evidence for ${repair.sourceIdentity}: ${englishNames.join(', ')}`,
    );
  }
});

function parseLastJsonObject<T>(stdout: string): T {
  const rootStart = Math.max(stdout.lastIndexOf('\n{'), stdout.startsWith('{') ? 0 : -1);
  assert.notEqual(rootStart, -1, `No JSON object found in child output:\n${stdout}`);
  return JSON.parse(stdout.slice(rootStart === 0 ? 0 : rootStart + 1)) as T;
}

function runNode(script: string, args: string[], environment: Record<string, string | undefined> = {}) {
  // 测试经 npm scripts 运行，PATH 上必有 node；用固定程序名 + 参数数组，
  // 不把解释器路径或数据拼进命令。
  const result = spawnSync('node', [script, ...args], {
    cwd: WEBSITE_ROOT,
    encoding: 'utf8',
    env: { ...process.env, ...environment },
  });
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  return result;
}

const SNAPSHOT_QUERY_SCRIPT = path.join(
  WEBSITE_ROOT, 'tests', 'helpers', 'legacy-series-snapshot-query.js');
const PREPARE_FIXTURE_SCRIPT = path.join(
  WEBSITE_ROOT, 'tests', 'helpers', 'legacy-series-prepare-fixture.js');

function databaseSnapshot(databaseUrl: string) {
  const identities = JSON.stringify(
    LEGACY_SERIES_CONTENT_REPAIRS.map((item) => item.sourceIdentity));
  return parseLastJsonObject<{
    series: unknown[];
    products: unknown[];
    variants: unknown[];
    sourceAudit: { count: number; digest: string };
    repaired: Array<{ sourceIdentity: string; i18n: { zh?: { name?: string }; en?: { name?: string } } }>;
  }>(runNode(SNAPSHOT_QUERY_SCRIPT, [identities], { DATABASE_URL: databaseUrl }).stdout);
}

function prepareCopiedLegacyFixture(databaseUrl: string): void {
  const fixture = JSON.stringify(LEGACY_SERIES_CONTENT_REPAIRS.map((repair) => ({
    sourceIdentity: repair.sourceIdentity,
    zh: firstNonTargetSourceName(repair.allowedSourceNames.zh, repair.publicNames.zh),
    en: firstNonTargetSourceName(repair.allowedSourceNames.en, repair.publicNames.en),
  })));
  runNode(PREPARE_FIXTURE_SCRIPT, [fixture], { DATABASE_URL: databaseUrl });
}

test('copied database apply is atomic, audited and idempotent', { timeout: 120_000 }, async () => {
  const sourceDatabase = path.join(WEBSITE_ROOT, 'prisma', 'dev.db');
  const temporaryRoot = await mkdtemp(path.join(WEBSITE_ROOT, TEMPORARY_PREFIX));
  assert.equal(path.dirname(temporaryRoot), WEBSITE_ROOT);
  assert.match(path.basename(temporaryRoot), TEMPORARY_PATTERN);
  const copiedDatabase = path.join(temporaryRoot, 'catalog-copy.db');
  const databaseUrl = `file:${copiedDatabase.replaceAll('\\', '/')}`;
  const cli = path.join(WEBSITE_ROOT, 'node_modules', 'tsx', 'dist', 'cli.mjs');
  const repairScript = path.join(WEBSITE_ROOT, 'prisma', 'repair-legacy-series-content.ts');
  try {
    await copyFile(sourceDatabase, copiedDatabase);
    prepareCopiedLegacyFixture(databaseUrl);
    const beforeFileDigest = sha256(await readFile(copiedDatabase));
    const before = databaseSnapshot(databaseUrl);

    const dryRun = runNode(cli, [repairScript, '--database', copiedDatabase]);
    const dryRunResult = parseLastJsonObject<{
      summary: { expectedSeries: number; chineseAnomaliesBefore: number; englishPollutionBefore: number };
      changes: { series: number };
      issues: string[];
    }>(dryRun.stdout);
    assert.deepEqual(dryRunResult.issues, []);
    assert.equal(dryRunResult.summary.expectedSeries, 50);
    assert.equal(dryRunResult.summary.chineseAnomaliesBefore, 50);
    assert.equal(dryRunResult.summary.englishPollutionBefore, 25);
    assert.equal(dryRunResult.changes.series, 50);
    assert.equal(sha256(await readFile(copiedDatabase)), beforeFileDigest, 'dry-run must not write the copied DB');

    const firstApply = runNode(cli, [repairScript, '--apply', '--database', copiedDatabase], {
      UTEN_LEGACY_SERIES_CONTENT_CONFIRM: 'APPLY_REVIEWED_LEGACY_SERIES_CONTENT',
    });
    const firstResult = parseLastJsonObject<{
      status: string;
      changes: { series: number };
      backupPath: string;
      auditPath: string;
    }>(firstApply.stdout);
    assert.equal(firstResult.status, 'applied');
    assert.equal(firstResult.changes.series, 50);
    assert.ok(existsSync(firstResult.backupPath));
    assert.ok(existsSync(firstResult.auditPath));

    const after = databaseSnapshot(databaseUrl);
    assert.deepEqual(after.series, before.series);
    assert.deepEqual(after.products, before.products);
    assert.deepEqual(after.variants, before.variants);
    assert.deepEqual(after.sourceAudit, before.sourceAudit);
    assert.equal(after.repaired.length, 50);
    const repairs = new Map(LEGACY_SERIES_CONTENT_REPAIRS.map((item) => [item.sourceIdentity, item]));
    for (const row of after.repaired) {
      const repair = repairs.get(row.sourceIdentity);
      assert.ok(repair);
      assert.equal(row.i18n.zh?.name, repair.publicNames.zh);
      assert.equal(row.i18n.en?.name, repair.publicNames.en);
    }

    const secondApply = runNode(cli, [repairScript, '--apply', '--database', copiedDatabase], {
      UTEN_LEGACY_SERIES_CONTENT_CONFIRM: 'APPLY_REVIEWED_LEGACY_SERIES_CONTENT',
    });
    const secondResult = parseLastJsonObject<{
      status: string;
      changes: { series: number };
      backupPath: null;
      auditPath: null;
    }>(secondApply.stdout);
    assert.equal(secondResult.status, 'already-clean');
    assert.deepEqual(secondResult.changes, { series: 0 });
    assert.equal(secondResult.backupPath, null);
    assert.equal(secondResult.auditPath, null);
    assert.deepEqual(databaseSnapshot(databaseUrl), after);
  } finally {
    const exactRoot = path.resolve(temporaryRoot);
    if (path.dirname(exactRoot) !== WEBSITE_ROOT || !TEMPORARY_PATTERN.test(path.basename(exactRoot))) {
      throw new Error(`Refusing to clean unexpected test directory: ${exactRoot}`);
    }
    await rm(exactRoot, { recursive: true, force: true });
  }
});
