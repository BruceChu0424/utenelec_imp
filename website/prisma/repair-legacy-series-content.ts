import type { PrismaClient } from '@prisma/client';
import { createHash, randomUUID } from 'node:crypto';
import { access, lstat, mkdir, realpath, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import {
  buildLegacySeriesContentPlan,
  LEGACY_SOURCE_SYSTEM,
  type LegacySeriesContentPlan,
  type LegacySeriesContentSnapshot,
} from '../scripts/lib/legacy-series-content';

const APPLY_CONFIRMATION_ENV = 'UTEN_LEGACY_SERIES_CONTENT_CONFIRM';
const APPLY_CONFIRMATION_VALUE = 'APPLY_REVIEWED_LEGACY_SERIES_CONTENT';

type Options = {
  apply: boolean;
  databasePath: string;
  backupDir: string;
  reportPath: string | null;
};

function usage(): string {
  return `UTEN legacy Series content repair

Dry-run (default; database is read-only):
  tsx prisma/repair-legacy-series-content.ts [--database <sqlite.db>] [--report <plan.json>]

Apply (requires an explicit database and confirmation environment variable):
  ${APPLY_CONFIRMATION_ENV}=${APPLY_CONFIRMATION_VALUE} \\
  tsx prisma/repair-legacy-series-content.ts --apply --database <sqlite.db> [--backup-dir <directory>]

Apply creates a SQLite VACUUM INTO backup before one atomic transaction. It only
updates the zh/en name fields of 50 exact ${LEGACY_SOURCE_SYSTEM}:series:<legacyId>
records. It refuses unknown/manual names and never changes source identities,
hierarchy, publication, products, variants, media or immutable source audit rows.`;
}

function valueAfter(argv: string[], index: number, name: string): string {
  const value = argv[index + 1];
  if (!value || value.startsWith('--')) throw new Error(`${name} requires a value.\n\n${usage()}`);
  return value;
}

function parseOptions(argv: string[]): Options {
  let apply = false;
  let database: string | null = null;
  let backupDir: string | null = null;
  let reportPath: string | null = null;
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--apply') {
      if (apply) throw new Error(`Duplicate --apply.\n\n${usage()}`);
      apply = true;
      continue;
    }
    if (argument === '--database') {
      if (database) throw new Error(`Duplicate --database.\n\n${usage()}`);
      database = valueAfter(argv, index, '--database');
      index += 1;
      continue;
    }
    if (argument === '--backup-dir') {
      if (backupDir) throw new Error(`Duplicate --backup-dir.\n\n${usage()}`);
      backupDir = valueAfter(argv, index, '--backup-dir');
      index += 1;
      continue;
    }
    if (argument === '--report') {
      if (reportPath) throw new Error(`Duplicate --report.\n\n${usage()}`);
      reportPath = valueAfter(argv, index, '--report');
      index += 1;
      continue;
    }
    throw new Error(`Unknown argument ${argument}.\n\n${usage()}`);
  }
  if (apply && !database) throw new Error(`Apply requires an explicit --database path.\n\n${usage()}`);
  const databasePath = path.resolve(database ?? path.join('prisma', 'dev.db'));
  return {
    apply,
    databasePath,
    backupDir: path.resolve(
      backupDir ?? path.join(path.dirname(databasePath), 'backups', 'legacy-series-content'),
    ),
    reportPath: reportPath ? path.resolve(reportPath) : null,
  };
}

function sqliteUrl(databasePath: string): string {
  return `file:${databasePath.replaceAll('\\', '/')}`;
}

async function assertRegularDatabase(databasePath: string): Promise<string> {
  await access(databasePath);
  const metadata = await lstat(databasePath);
  if (!metadata.isFile() || metadata.isSymbolicLink()) {
    throw new Error(`Refusing non-regular or symlinked SQLite database: ${databasePath}`);
  }
  return realpath(databasePath);
}

async function writeJson(filename: string, value: unknown): Promise<void> {
  await mkdir(path.dirname(filename), { recursive: true });
  await writeFile(filename, `${JSON.stringify(value, null, 2)}\n`, { encoding: 'utf8', flag: 'wx' });
}

async function createBackup(prisma: PrismaClient, databasePath: string, backupDir: string): Promise<string> {
  const realDatabase = await assertRegularDatabase(databasePath);
  await mkdir(backupDir, { recursive: true });
  const realBackupDir = await realpath(backupDir);
  const publicRoot = await realpath(path.resolve('public')).catch(() => path.resolve('public'));
  if (realBackupDir === publicRoot || realBackupDir.startsWith(`${publicRoot}${path.sep}`)) {
    throw new Error('SQLite backups must not be placed below public/.');
  }
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
  const backupPath = path.join(
    realBackupDir,
    `${path.basename(realDatabase)}.${timestamp}.${randomUUID().slice(0, 8)}.sqlite`,
  );
  const escaped = backupPath.replaceAll('\\', '/').replaceAll("'", "''");
  await prisma.$executeRawUnsafe(`VACUUM INTO '${escaped}'`);
  const metadata = await stat(backupPath);
  if (!metadata.isFile() || metadata.size === 0) throw new Error(`SQLite backup failed: ${backupPath}`);
  return backupPath;
}

function planDigest(plan: LegacySeriesContentPlan): string {
  return createHash('sha256').update(JSON.stringify(plan)).digest('hex');
}

async function applyPlan(prisma: PrismaClient, plan: LegacySeriesContentPlan): Promise<void> {
  if (plan.issues.length) throw new Error(`Plan contains blocking issues:\n- ${plan.issues.join('\n- ')}`);
  await prisma.$transaction(async (tx) => {
    for (const update of plan.updates) {
      const result = await tx.series.updateMany({
        where: {
          id: update.id,
          sourceIdentity: update.sourceIdentity,
          legacySource: LEGACY_SOURCE_SYSTEM,
          legacyId: update.sourceId,
          rowVersion: update.expectedRowVersion,
          i18n: update.expectedI18n,
        },
        data: {
          i18n: update.i18n,
          rowVersion: { increment: 1 },
        },
      });
      if (result.count !== 1) {
        throw new Error(`${update.sourceIdentity} changed after planning; transaction rolled back.`);
      }
    }
  }, { maxWait: 30_000, timeout: 120_000 });
}

async function readInput(prisma: PrismaClient): Promise<LegacySeriesContentSnapshot[]> {
  return prisma.series.findMany({
    where: { legacySource: LEGACY_SOURCE_SYSTEM },
    select: {
      id: true,
      sourceIdentity: true,
      legacySource: true,
      legacyId: true,
      i18n: true,
      rowVersion: true,
    },
  });
}

async function main(): Promise<void> {
  const options = parseOptions(process.argv.slice(2));
  if (options.apply && process.env[APPLY_CONFIRMATION_ENV] !== APPLY_CONFIRMATION_VALUE) {
    throw new Error(
      `Apply refused. Set ${APPLY_CONFIRMATION_ENV}=${APPLY_CONFIRMATION_VALUE} after reviewing dry-run output.`,
    );
  }
  options.databasePath = await assertRegularDatabase(options.databasePath);
  process.env.DATABASE_URL = sqliteUrl(options.databasePath);
  const clientModule = process.env.UTEN_CATALOG_PRISMA_CLIENT_MODULE || '@prisma/client';
  const loadedClient = await import(clientModule) as { PrismaClient: new () => PrismaClient };
  const prisma = new loadedClient.PrismaClient();
  try {
    const [input, sourceAuditRecords] = await Promise.all([
      readInput(prisma),
      prisma.legacySourceRecord.count({
        where: { sourceSystem: LEGACY_SOURCE_SYSTEM, entityType: 'series' },
      }),
    ]);
    const plan = buildLegacySeriesContentPlan(input);
    const result = {
      mode: options.apply ? 'apply' : 'dry-run',
      databasePath: options.databasePath,
      planDigest: planDigest(plan),
      summary: plan.summary,
      sourceAuditRecords,
      issues: plan.issues,
      changes: { series: plan.updates.length },
      samples: plan.updates.slice(0, 50),
    };
    if (!options.apply) {
      if (options.reportPath) await writeJson(options.reportPath, { ...result, plan });
      console.log(JSON.stringify({ ...result, reportPath: options.reportPath }, null, 2));
      if (plan.issues.length) process.exitCode = 1;
      return;
    }
    if (plan.issues.length) {
      throw new Error(`Apply refused because dry-run found ${plan.issues.length} blocking issue(s).`);
    }
    if (!plan.updates.length) {
      console.log(JSON.stringify({
        ...result,
        status: 'already-clean',
        backupPath: null,
        auditPath: null,
      }, null, 2));
      return;
    }

    const backupPath = await createBackup(prisma, options.databasePath, options.backupDir);
    const auditPath = `${backupPath}.legacy-series-content.json`;
    await applyPlan(prisma, plan);
    await writeJson(auditPath, {
      ...result,
      status: 'applied',
      appliedAt: new Date().toISOString(),
      backupPath,
      plan,
    });
    console.log(JSON.stringify({
      ...result,
      status: 'applied',
      backupPath,
      auditPath,
    }, null, 2));
  } finally {
    await prisma.$disconnect();
  }
}

main().catch((error) => {
  console.error(`[legacy-series-content] ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 1;
});
