import path from 'node:path';
import { lstat, access, readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { PrismaClient as SqliteClient } from '@prisma/client';
import { PrismaClient as PostgresClient } from '../generated/postgresql/index.js';
import { websiteMigrationTables, assertMigrationModelCoverage } from './migration-contract.mjs';

const args = process.argv.slice(2), sourceArgument = args[args.indexOf('--source') + 1];
if (!args.includes('--source') || !sourceArgument || !path.isAbsolute(sourceArgument)) throw new Error('--source must be an absolute, offline SQLite backup path');
const sourcePath = path.resolve(sourceArgument), info = await lstat(sourcePath);
if (!info.isFile() || info.isSymbolicLink()) throw new Error('Source must be a real offline backup file');
for (const suffix of ['-wal', '-journal']) {
  try { await access(sourcePath + suffix); throw new Error('Source has a journal; make a consistent offline backup first'); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
}
const url = new URL(process.env.DATABASE_URL || '');
if (!['postgres:', 'postgresql:'].includes(url.protocol)) throw new Error('DATABASE_URL must select PostgreSQL');
if (!['localhost', '127.0.0.1', '[::1]'].includes(url.hostname) && !args.includes('--allow-remote-target')) {
  throw new Error('Remote migration requires separate deployment approval and --allow-remote-target');
}
const apply = args.includes('--apply');
if (apply && (!args.includes('--confirm') || args[args.indexOf('--confirm') + 1] !== 'WEBSITE_POSTGRESQL_MIGRATION')) throw new Error('Explicit migration confirmation required');
assertMigrationModelCoverage(await readFile(new URL('../prisma/schema.prisma', import.meta.url), 'utf8'));
const tables = websiteMigrationTables;
const sqlite = new SqliteClient({ datasources: { db: { url: 'file:' + sourcePath.replaceAll('\\', '/') } } });
const postgres = new PostgresClient();
const canonical = value => value instanceof Date ? value.toISOString() : Array.isArray(value) ? value.map(canonical)
  : value && typeof value === 'object' ? Object.fromEntries(Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => [k, canonical(v)])) : value;
const hash = rows => createHash('sha256').update(JSON.stringify(canonical([...rows].sort((a, b) => String(a.id || a.publicPath).localeCompare(String(b.id || b.publicPath)))))).digest('hex');
try {
  const source = await sqlite.$transaction(async tx => Object.fromEntries(await Promise.all(tables.map(async table => [table, await tx[table].findMany()]))), { timeout: 120000 });
  const existing = await Promise.all(tables.map(async table => [table, await postgres[table].count()]));
  if (existing.some(([, count]) => count !== 0)) throw new Error('Destination has application records; refusing to merge or overwrite');
  const expected = Object.fromEntries(tables.map(table => [table, { count: source[table].length, sha256: hash(source[table]) }]));
  if (!apply) { console.log(JSON.stringify({ mode: 'dry-run', emptyTarget: true, tables: expected }, null, 2)); }
  else {
    await postgres.$transaction(async tx => {
      for (const table of tables) {
        const rows = table === 'series' ? source[table].map(row => ({ ...row, parentId: null })) : source[table];
        for (let i = 0; i < rows.length; i += 200) await tx[table].createMany({ data: rows.slice(i, i + 200) });
        if (table === 'series') for (const row of source.series) if (row.parentId) await tx.series.update({ where: { id: row.id }, data: { parentId: row.parentId, updatedAt: row.updatedAt } });
      }
      for (const table of tables) {
        const rows = await tx[table].findMany();
        if (rows.length !== expected[table].count || hash(rows) !== expected[table].sha256) throw new Error('Migration readback mismatch: ' + table);
      }
    }, { timeout: 180000 });
    console.log(JSON.stringify({ mode: 'applied', readbackVerified: true, tables: expected }, null, 2));
  }
} finally { await sqlite.$disconnect(); await postgres.$disconnect(); }
