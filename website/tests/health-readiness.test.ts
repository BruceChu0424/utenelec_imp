import assert from 'node:assert/strict';
import { mkdir, stat, symlink, writeFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { migratedDatabase } from './helpers/migrated-database';
import { assertDocumentsDirectoryReady } from '../lib/document-storage';

test('readiness includes the private document store and never returns internal paths or exceptions', async (t) => {
  const fixture = await migratedDatabase();
  const keys = ['DATABASE_URL', 'UPLOADS_DIR', 'DOCUMENTS_DIR', 'NODE_ENV'] as const;
  const previous = new Map(keys.map(key => [key, process.env[key]]));
  const documents = path.join(fixture.temporaryRoot, 'documents');
  Object.assign(process.env, { DATABASE_URL: fixture.databaseUrl, NODE_ENV: 'test',
    UPLOADS_DIR: path.join(fixture.temporaryRoot, 'uploads'), DOCUMENTS_DIR: documents });
  const { prisma } = await import('../lib/db');
  const { GET } = await import('../app/api/health/route');
  const unavailable = async () => {
    const response = await GET();
    assert.equal(response.status, 503);
    assert.equal(response.headers.get('Cache-Control'), 'no-store, max-age=0');
    assert.deepEqual(await response.json(), { status: 'unavailable' });
  };
  try {
    await t.test('a migrated database and both usable storage directories are ready', async () => {
      const response = await GET();
      assert.equal(response.status, 200);
      assert.deepEqual(await response.json(), { status: 'ok' });
      assert.equal((await stat(documents)).isDirectory(), true);
    });
    await t.test('a file in place of the private directory fails even while database and uploads stay ready', async () => {
      const blocked = path.join(fixture.temporaryRoot, 'private-store-is-a-file');
      await writeFile(blocked, 'synthetic readiness fixture');
      process.env.DOCUMENTS_DIR = blocked;
      await unavailable();
      process.env.DOCUMENTS_DIR = documents;
      assert.equal((await GET()).status, 200);
    });
    await t.test('a symbolic-link private directory is not accepted as a ready store', async () => {
      const alias = path.join(fixture.temporaryRoot, 'private-store-alias');
      await symlink(documents, alias, process.platform === 'win32' ? 'junction' : 'dir');
      process.env.DOCUMENTS_DIR = alias;
      await unavailable();
      process.env.DOCUMENTS_DIR = documents;
    });
    await t.test('production refuses an alternative missing directory instead of silently creating it', async () => {
      const unapproved = path.join(fixture.temporaryRoot, 'release', 'documents');
      Object.assign(process.env, { NODE_ENV: 'production', DOCUMENTS_DIR: unapproved });
      await assert.rejects(assertDocumentsDirectoryReady(), /approved durable mount/);
      await assert.rejects(stat(unapproved), (error: NodeJS.ErrnoException) => error.code === 'ENOENT');
      await unavailable();
      Object.assign(process.env, { NODE_ENV: 'test', DOCUMENTS_DIR: documents });
    });
    await t.test('document tables are required even when a completed baseline and storage remain available', async () => {
      await mkdir(documents, { recursive: true });
      await prisma.$executeRawUnsafe('DROP TABLE "ResourceDocument"');
      await unavailable();
    });
  } finally {
    await prisma.$disconnect();
    for (const [key, value] of previous) {
      if (value === undefined) delete process.env[key];
      else Object.assign(process.env, { [key]: value });
    }
    await fixture.dispose();
  }
});
