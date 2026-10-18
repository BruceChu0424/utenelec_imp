import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import { assertMigrationModelCoverage, websiteMigrationTables } from '../scripts/migration-contract.mjs';
test('SQLite to PostgreSQL migration covers every real schema model including series media', async () => {
  const schema = await readFile(new URL('../prisma/schema.prisma', import.meta.url), 'utf8');
  assert.equal(assertMigrationModelCoverage(schema), websiteMigrationTables.length);
  assert.ok(websiteMigrationTables.includes('seriesMedia'));
  assert.throws(() => assertMigrationModelCoverage(schema + '\nmodel FutureContent {\n id String @id\n}\n'), /missing=futureContent/);
});
