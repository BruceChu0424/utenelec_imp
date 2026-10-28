import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { PDFDocument } from 'pdf-lib';
import { storeDocument } from '../lib/document-storage';
import { createIsolatedPostgresqlDatabase, postgresqlTestsEnabled } from './helpers/isolated-postgresql';

test('B1 public document and inquiry readers execute against their private PostgreSQL database', { skip: !postgresqlTestsEnabled(), timeout: 120_000 }, async t => {
  const fixture = await createIsolatedPostgresqlDatabase('b1_reads');
  const url = new URL(fixture.databaseUrl);
  assert.equal(url.hostname, '127.0.0.1');
  assert.match(url.pathname, /^\/uten_website_cms_test_b1_reads_[a-z0-9_]+$/);
  process.env.DATABASE_URL = fixture.databaseUrl;
  process.env.UTEN_WEBSITE_BRIDGE_TOKEN = 'B1_SYNTHETIC_BRIDGE_TOKEN_00000000000000000000001';
  process.env.WEB_SITE_ID = 'b1-synthetic';
  const root = await mkdtemp(path.join(os.tmpdir(), 'uten-b1-public-read-'));
  process.env.DOCUMENTS_DIR = root;
  const cache = globalThis as unknown as { prisma?: typeof fixture.client };
  const previousClient = cache.prisma; cache.prisma = fixture.client;
  const { prisma } = await import('../lib/db');
  const { GET: download } = await import('../app/api/resources/[id]/download/route');
  const { GET: pending } = await import('../app/api/imp/bridge/inquiries/route');
  const { acknowledgeInquiries } = await import('../lib/inquiry-delivery');
  try {
    assert.equal((await prisma.$queryRawUnsafe<{ current_database: string }[]>('SELECT current_database()'))[0].current_database, url.pathname.substring(1));
    const pdf = await PDFDocument.create(); pdf.addPage();
    const original = await pdf.save(); const bytes = new Uint8Array(512 * 1024).fill(32); bytes.set(original);
    const stored = await storeDocument(bytes);
    const asset = await prisma.websiteDocumentAsset.create({ data: { ...stored, originalName: '合成产品原件.pdf', createdBy: 'b1-synthetic' } });
    const resource = await prisma.resourceDocument.create({ data: { id: 'b1-resource', slug: 'b1-resource', i18n: '{"zh":{"title":"合成资料"}}', language: 'zh', version: 'fixture', assetId: asset.id, published: true } });
    const request = () => new Request('http://127.0.0.1/api/resources/b1-resource/download');
    const params = { params: Promise.resolve({ id: resource.id }) };
    await t.test('public download keeps the complete original and bounded content headers', async () => {
      const response = await download(request(), params);
      assert.equal(response.status, 200); assert.equal(response.headers.get('content-length'), String(bytes.length));
      assert.equal(response.headers.get('content-type'), 'application/pdf');
      assert.deepEqual(new Uint8Array(await response.arrayBuffer()), bytes);
    });
    await t.test('physical slots include unconsumed bodies and are released by cancellation', async () => {
      const first = await download(request(), params), second = await download(request(), params);
      assert.equal(first.status, 200); assert.equal(second.status, 200);
      const busy = await download(request(), params); assert.equal(busy.status, 503); assert.equal(busy.headers.get('retry-after'), '2');
      await first.body!.cancel(); await second.body!.cancel();
    });
    await t.test('withdrawing publication interrupts a started body and blocks subsequent reads', async () => {
      const response = await download(request(), params); assert.equal(response.status, 200);
      const reader = response.body!.getReader(); const first = await reader.read(); assert.equal(first.done, false);
      await prisma.resourceDocument.update({ where: { id: resource.id }, data: { published: false } });
      let received = first.value!.length;
      await assert.rejects(async () => { for (;;) { const next = await reader.read(); if (next.done) break; received += next.value.length; } }, /publication changed/);
      assert.ok(received < bytes.length); assert.equal((await download(request(), params)).status, 404);
      assert.equal(await prisma.websiteDocumentAsset.count(), 1, 'withdrawing a public copy never deletes its original');
      await prisma.resourceDocument.update({ where: { id: resource.id }, data: { published: true } });
    });
    await t.test('publication waits have a physical PostgreSQL statement boundary and recover their download slot', async () => {
      let releaseLock!: () => void, acquiredLock!: () => void;
      const release = new Promise<void>(resolve => { releaseLock = resolve; });
      const acquired = new Promise<void>(resolve => { acquiredLock = resolve; });
      let armed = true, started = false, statementTimedOut = false;
      let locker: Promise<void> | undefined;
      prisma.$use(async (parameters, next) => {
        if (!armed || parameters.model !== 'ResourceDocument' || parameters.action !== 'findFirst') return next(parameters);
        if (parameters.args?.include?.asset && !started) {
          const result = await next(parameters); started = true;
          // The first lookup must commit before the exclusive table lock can
          // enter; publication has not yet touched this table in its new tx.
          locker = fixture.client.$transaction(async tx => {
            await tx.$executeRawUnsafe('LOCK TABLE "ResourceDocument" IN ACCESS EXCLUSIVE MODE');
            acquiredLock(); await release;
          }, { maxWait: 1_000, timeout: 10_000 });
          void locker.catch(() => {});
          return result;
        }
        if (parameters.args?.select?.assetId) {
          await acquired;
          try { return await next(parameters); }
          catch (failure) { statementTimedOut = /statement timeout/i.test(String(failure)); throw failure; }
        }
        return next(parameters);
      });
      try {
        const startedAt = Date.now(); const response = await download(request(), params);
        assert.equal(response.status, 503);
        assert.equal(statementTimedOut, true, 'PostgreSQL canceled the actual statement, not just its JavaScript waiter');
        assert.ok(Date.now() - startedAt < 5_000);
        const blocked = await fixture.client.$queryRawUnsafe<{ count: bigint }[]>(
          `SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND state='active'
             AND wait_event_type='Lock' AND query LIKE '%ResourceDocument%'`);
        assert.equal(Number(blocked[0].count), 0, 'no canceled publication query remains waiting on the database lock');
      } finally {
        armed = false; releaseLock(); await locker;
      }
      const restored = await download(request(), params); assert.equal(restored.status, 200);
      await restored.body!.cancel();
    });
    const createdAt = new Date('2026-01-01T00:00:00.000Z');
    for (let index = 0; index < 121; index++) {
      const suffix = String(index).padStart(4, '0');
      await prisma.inquiry.create({ data: { id: `b1-inquiry-${suffix}`, name: `合成联系人${suffix}`, message: '仅隔离测试',
        sourceContext: '{"original":"原始输入"}', createdAt,
        delivery: { create: { id: `b1-delivery-${suffix}`, createdAt } } } });
    }
    const authorized = (limit: string) => new Request(`http://127.0.0.1/api/imp/bridge/inquiries?limit=${limit}`, {
      headers: { authorization: `Bearer ${process.env.UTEN_WEBSITE_BRIDGE_TOKEN}`, 'x-uten-site-id': 'b1-synthetic' },
    });
    await t.test('bridge authority, tie ordering and the 50-row limit stay independent of ERP exports', async () => {
      assert.equal((await pending(new Request('http://127.0.0.1/api/imp/bridge/inquiries'))).status, 401);
      const response = await pending(authorized('100000')); assert.equal(response.status, 200);
      const result = await response.json() as { items: { deliveryId: string; sourceId: string }[] };
      assert.equal(result.items.length, 50); assert.equal(result.items[0].deliveryId, 'b1-delivery-0000');
      assert.equal(result.items[49].deliveryId, 'b1-delivery-0049');
      const repeated = await (await pending(authorized('100000'))).json(); assert.deepEqual(repeated, result);
      assert.equal((await (await pending(authorized('NaN'))).json()).items.length, 20);
      assert.equal((await (await pending(authorized('-1'))).json()).items.length, 1);
    });
    await t.test('concurrent same receipts and unknown-commit retries retain source identities', async () => {
      const receipts = Array.from({ length: 50 }, (_, index) => {
        const suffix = String(index).padStart(4, '0'); return { deliveryId: `b1-delivery-${suffix}`, sourceId: `b1-inquiry-${suffix}`, erpInquiryId: `b1-erp-${suffix}` };
      });
      const results = await Promise.allSettled([acknowledgeInquiries(receipts), acknowledgeInquiries(receipts)]);
      assert.ok(results.every(result => result.status === 'fulfilled'), JSON.stringify(results));
      assert.deepEqual(await acknowledgeInquiries(receipts), { acknowledged: 50 });
      const next = await (await pending(authorized('50'))).json(); assert.equal(next.items[0].deliveryId, 'b1-delivery-0050');
      await assert.rejects(acknowledgeInquiries([{ ...receipts[0], erpInquiryId: 'different-original' }]));
      assert.equal(await prisma.inquiry.count(), 121); assert.equal(await prisma.inquiryDelivery.count(), 121);
      assert.ok((await prisma.inquiry.findUniqueOrThrow({ where: { id: receipts[0].sourceId } })).sourceContext?.includes('原始输入'));
    });
    await t.test('reverse receipt order does not deadlock and a fully acknowledged reader becomes empty', async () => {
      const receipts = Array.from({ length: 50 }, (_, index) => {
        const suffix = String(index + 50).padStart(4, '0'); return { deliveryId: `b1-delivery-${suffix}`, sourceId: `b1-inquiry-${suffix}`, erpInquiryId: `b1-erp-${suffix}` };
      });
      const results = await Promise.allSettled([acknowledgeInquiries(receipts), acknowledgeInquiries([...receipts].reverse())]);
      assert.ok(results.every(result => result.status === 'fulfilled'), JSON.stringify(results));
      const remaining = await (await pending(authorized('50'))).json(); assert.equal(remaining.items.length, 21);
      // A later bad source must roll back an earlier valid update in this batch.
      const first = remaining.items[0], second = remaining.items[1];
      await assert.rejects(acknowledgeInquiries([
        { ...first, erpInquiryId: 'rollback-first' },
        { ...second, sourceId: 'wrong-source', erpInquiryId: 'rollback-second' },
      ]));
      const untouched = await prisma.inquiryDelivery.findMany({
        where: { id: { in: [first.deliveryId, second.deliveryId] } },
        orderBy: { id: 'asc' }, select: { state: true, erpInquiryId: true, acknowledgedAt: true },
      });
      assert.deepEqual(untouched, [
        { state: 'PENDING', erpInquiryId: null, acknowledgedAt: null },
        { state: 'PENDING', erpInquiryId: null, acknowledgedAt: null },
      ]);
      await acknowledgeInquiries(remaining.items.map((item: { deliveryId: string; sourceId: string }) => ({ ...item, erpInquiryId: `erp-${item.sourceId}` })));
      assert.deepEqual(await (await pending(authorized('50'))).json(), { items: [] });
      assert.equal(await prisma.inquiry.count(), 121); assert.equal(await prisma.inquiryDelivery.count(), 121);
    });
  } finally {
    await prisma.$disconnect(); cache.prisma = previousClient; delete process.env.DATABASE_URL; delete process.env.DOCUMENTS_DIR;
    delete process.env.UTEN_WEBSITE_BRIDGE_TOKEN; delete process.env.WEB_SITE_ID;
    assert.equal(path.dirname(path.resolve(root)), path.resolve(os.tmpdir())); assert.ok(path.basename(root).startsWith('uten-b1-public-read-'));
    await rm(root, { recursive: true, force: true });
    await fixture.dispose();
  }
});
