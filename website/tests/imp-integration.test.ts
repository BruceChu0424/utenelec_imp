import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { randomBytes, randomUUID } from 'node:crypto';
import { migratedDatabase } from './helpers/migrated-database';
import { authorizeBridge, boundedJson, BridgeError, digest, requireSameOrigin, isBridgeTokenConfigured } from '../lib/imp-bridge-security';

let database: Awaited<ReturnType<typeof migratedDatabase>>;
let db: typeof import('../lib/db').prisma;
let delivery: typeof import('../lib/inquiry-delivery');
let portal: typeof import('../lib/imp-portal');
before(async () => {
  database = await migratedDatabase(); process.env.DATABASE_URL = database.databaseUrl;
  process.env.WEB_SITE_ID = 'uten'; process.env.UTEN_WEBSITE_BRIDGE_TOKEN = randomBytes(48).toString('base64url');
  process.env.SITE_URL = 'https://website.example.test';
  db = (await import('../lib/db')).prisma;
  delivery = await import('../lib/inquiry-delivery'); portal = await import('../lib/imp-portal');
});
after(async () => { await db?.$disconnect(); await database?.dispose(); });
const input = (key = randomUUID()) => ({ name: 'Local integration visitor', email: 'integration@example.test',
  message: 'Please contact our project team', locale: 'en', source: 'product', submissionKey: key,
  consentAt: new Date(), consentPolicyVersion: 'test-v1', sourceContext: '{"products":[]}' });

test('persisted inquiry and queue survive repeated client submission and retain one stable receipt', async () => {
  const value = input(); const receipt = await delivery.persistInquiry(value);
  const replays = await Promise.all(Array.from({ length: 5 }, () => delivery.persistInquiry({ ...value, consentAt: new Date() })));
  assert.deepEqual(new Set(replays), new Set([receipt]));
  assert.equal(await db.inquiry.count({ where: { submissionKey: value.submissionKey } }), 1);
  assert.equal(await db.inquiryDelivery.count({ where: { inquiryId: receipt } }), 1);
  await assert.rejects(delivery.persistInquiry({ ...value, message: 'Changed payload' }), /SUBMISSION_CHANGED/);
  assert.equal((await db.inquiry.findUniqueOrThrow({ where: { id: receipt } })).message, value.message);
});
test('durable pending reads are non-destructive and receipts commit atomically', async () => {
  const sourceId = await delivery.persistInquiry(input());
  const first = await delivery.pendingInquiries(50);
  assert.deepEqual(await delivery.pendingInquiries(50), first);
  const item = first.find(row => row.sourceId === sourceId)!; assert.ok(item);
  const ack = { deliveryId: item.deliveryId, sourceId, erpInquiryId: randomUUID() };
  await assert.rejects(delivery.acknowledgeInquiries([ack, { ...ack, deliveryId: 'unknown' }]), /RECEIPT_MISMATCH/);
  assert.equal((await db.inquiryDelivery.findUniqueOrThrow({ where: { id: ack.deliveryId } })).state, 'PENDING');
  assert.deepEqual(await delivery.acknowledgeInquiries([ack]), { acknowledged: 1 });
  assert.deepEqual(await delivery.acknowledgeInquiries([ack]), { acknowledged: 1 });
  assert.ok(!(await delivery.pendingInquiries(50)).some(row => row.sourceId === sourceId));
  await assert.rejects(delivery.acknowledgeInquiries([{ ...ack, erpInquiryId: randomUUID() }]), /RECEIPT_MISMATCH/);
  assert.ok(await db.inquiry.findUnique({ where: { id: sourceId } }));
});
test('bridge identity is site-bound and errors do not disclose configuration', async () => {
  const request = (token: string, site: string) => new Request('https://website.example.test/api/imp/bridge/status', {
    headers: { authorization: `Bearer ${token}`, 'x-uten-site-id': site },
  });
  assert.throws(() => authorizeBridge(request('incorrect', 'uten')), /UNAUTHORIZED/);
  assert.throws(() => authorizeBridge(request(process.env.UTEN_WEBSITE_BRIDGE_TOKEN!, 'another')), /SITE_MISMATCH/);
  assert.equal(authorizeBridge(request(process.env.UTEN_WEBSITE_BRIDGE_TOKEN!, 'uten')), 'uten');
  assert.throws(() => requireSameOrigin(new Request('https://website.example.test', { headers: { origin: 'https://attacker.example' } })), /ORIGIN_MISMATCH/);
  assert.throws(() => requireSameOrigin(new Request('https://website.example.test')), /ORIGIN_MISMATCH/);
  requireSameOrigin(new Request('https://website.example.test', { headers: { origin: 'https://website.example.test' } }));
  await assert.rejects(boundedJson(new Request('https://website.example.test', { method: 'POST',
    headers: { 'content-type': 'application/json' }, body: JSON.stringify({ message: 'x'.repeat(1000) }) }), 64), /BODY_TOO_LARGE/);
});
const authorization = (challenge: string, actor = randomUUID()) => ({ requestId: randomUUID(), actorId: actor,
  authSessionId: randomUUID(),
  displayName: 'Local test editor', permissions: ['website:view', 'website:content_edit', 'unsupported:root'],
  section: 'home', expiresAt: new Date(Date.now() + 240_000).toISOString(), codeChallenge: challenge });
test('IMP authorization requires PKCE, is single-use and cannot elevate unknown permissions', async () => {
  const verifier = randomBytes(32).toString('base64url');
  const entry = await portal.registerPortalAuthorization(authorization(digest(verifier)), 'uten');
  await assert.rejects(portal.inspectPortalAuthorization(entry.code, randomBytes(32).toString('base64url')), /ENTRY_EXPIRED/);
  const inspected = await portal.inspectPortalAuthorization(entry.code, verifier);
  assert.equal(inspected.displayName, 'Local test editor');
  const result = await portal.consumePortalAuthorization(entry.code, verifier);
  assert.equal(result.destination, '/admin/settings?setting=hero');
  assert.deepEqual(JSON.parse(result.session.permissions), ['website:view', 'website:content_edit']);
  await assert.rejects(portal.consumePortalAuthorization(entry.code, verifier), /ENTRY_EXPIRED/);
  assert.ok(result.session.expiresAt.getTime() - Date.now() <= 240_000);
});
test('expired entries, wrong-site grants and revoked actors fail closed', async () => {
  const verifier = randomBytes(32).toString('base64url'), actor = randomUUID();
  const data = authorization(digest(verifier), actor);
  const entry = await portal.registerPortalAuthorization(data, 'uten');
  await db.impPortalAuthorization.update({ where: { requestId: data.requestId }, data: { expiresAt: new Date(0) } });
  await assert.rejects(portal.consumePortalAuthorization(entry.code, verifier), /ENTRY_EXPIRED/);
  const other = await portal.registerPortalAuthorization(authorization(digest(verifier)), 'another');
  await assert.rejects(portal.consumePortalAuthorization(other.code, verifier), /ENTRY_EXPIRED/);
  const valid = await portal.registerPortalAuthorization(authorization(digest(verifier), actor), 'uten');
  const { session } = await portal.consumePortalAuthorization(valid.code, verifier);
  await portal.revokePortalActor(actor);
  assert.ok((await db.impPortalSession.findUniqueOrThrow({ where: { id: session.id } })).revokedAt);
  await assert.rejects(portal.registerPortalAuthorization({ ...authorization(digest(verifier)), section: 'https://attacker.example' }, 'uten'), BridgeError);
  await assert.rejects(portal.registerPortalAuthorization({ ...authorization(digest(verifier)), permissions: ['website:publish'] }, 'uten'), /WEBSITE_ACCESS_REQUIRED/);
});

test('reverse leases refresh current permissions but never revive expired or revoked sessions', async () => {
  const verifier = randomBytes(32).toString('base64url'), actor = randomUUID();
  const grant = await portal.registerPortalAuthorization(authorization(digest(verifier), actor), 'uten');
  const { session } = await portal.consumePortalAuthorization(grant.code, verifier);
  assert.ok((await portal.activePortalSessions()).items.some(x => x.sessionId === session.id));
  const update = { sessionId: session.id, actorId: actor, permissions: ['website:view'], expiresAt: new Date(Date.now() + 290000).toISOString() };
  assert.deepEqual(await portal.renewPortalSessions([update]), { renewed: 1, revoked: 0, ignored: 0 });
  assert.deepEqual(JSON.parse((await db.impPortalSession.findUniqueOrThrow({ where: { id: session.id } })).permissions), ['website:view']);
  await assert.rejects(portal.renewPortalSessions([{ ...update, actorId: 'wrong' }]), /SESSION_ACTOR_MISMATCH/);
  await assert.rejects(portal.renewPortalSessions([{ ...update, expiresAt: new Date(Date.now() + 600000).toISOString() }]), /INVALID_LEASE_EXPIRY/);
  assert.deepEqual(await portal.renewPortalSessions([{ ...update, revoked: true }]), { renewed: 0, revoked: 1, ignored: 0 });
  assert.deepEqual(await portal.renewPortalSessions([update]), { renewed: 0, revoked: 0, ignored: 1 });
});

test('bridge token configuration contract rejects short and whitespace values consistently', () => {
  for (const size of [32, 42]) assert.equal(isBridgeTokenConfigured('a'.repeat(size)), false);
  assert.equal(isBridgeTokenConfigured('a'.repeat(43)), true);
  assert.equal(isBridgeTokenConfigured('a'.repeat(42) + ' '), false);
  assert.equal(isBridgeTokenConfigured('a'.repeat(513)), false);
});
test('revoking a current-site actor never revokes another site stored in the same database', async () => {
  const actor = randomUUID(), verifier = randomBytes(32).toString('base64url');
  const ours = authorization(digest(verifier), actor), other = authorization(digest(verifier), actor);
  await portal.registerPortalAuthorization(ours, 'uten'); await portal.registerPortalAuthorization(other, 'another-site');
  const foreign = await db.impPortalSession.create({ data: { id: randomUUID(), actorId: actor, authSessionId: randomUUID(), displayName: 'Other site',
    siteId: 'another-site', permissions: '["website:view"]', expiresAt: new Date(Date.now() + 240000) } });
  await portal.revokePortalActor(actor);
  assert.ok((await db.impPortalAuthorization.findUniqueOrThrow({ where: { requestId: ours.requestId } })).consumedAt);
  assert.equal((await db.impPortalAuthorization.findUniqueOrThrow({ where: { requestId: other.requestId } })).consumedAt, null);
  assert.equal((await db.impPortalSession.findUniqueOrThrow({ where: { id: foreign.id } })).revokedAt, null);
});
test('accepted client retries recover their original receipt after product changes, unpublication or policy changes', async () => {
  const { acceptInquiry } = await import('../lib/inquiry-acceptance');
  const family = await db.series.create({ data: { code: 'replay-family', catalogRole: 'FAMILY', published: true, i18n: '{"en":{"name":"Before family"}}' } });
  const product = await db.product.create({ data: { seriesId: family.id, slug: 'replay-model', published: true, i18n: '{"en":{"name":"Before product"}}' } });
  const data = { name: 'Retry visitor', email: 'retry@example.invalid', message: 'Stable request', source: 'product', locale: 'en' };
  const selected = { productId: product.id, variantId: '', seriesId: family.id }, key = randomUUID();
  const id = await acceptInquiry(data, selected, key);
  const original = await db.inquiry.findUniqueOrThrow({ where: { id } });
  await db.product.update({ where: { id: product.id }, data: { i18n: '{"en":{"name":"After product"}}', rowVersion: { increment: 1 }, published: false } });
  await db.series.update({ where: { id: family.id }, data: { i18n: '{"en":{"name":"After family"}}' } });
  await db.inquiry.update({ where: { id }, data: { consentPolicyVersion: 'previous-server-policy' } });
  assert.equal(await acceptInquiry(data, selected, key, () => false), id);
  assert.equal((await db.inquiry.findUniqueOrThrow({ where: { id } })).sourceContext, original.sourceContext);
  await assert.rejects(acceptInquiry({ ...data, message: 'Different request' }, selected, key), /SUBMISSION_CHANGED/);
  await assert.rejects(acceptInquiry(data, selected, randomUUID()), /PRODUCT_UNAVAILABLE/);
});
test('a concurrent acceptance is recovered when publication changes between first lookup and validation', async () => {
  const { acceptInquiry } = await import('../lib/inquiry-acceptance');
  const family = await db.series.create({ data: { code: 'race-family', catalogRole: 'FAMILY', published: true, i18n: '{"en":{"name":"Family"}}' } });
  const product = await db.product.create({ data: { slug: 'race-model', seriesId: family.id, published: true, i18n: '{"en":{"name":"Product"}}' } });
  const data = { name: 'Concurrent visitor', email: 'concurrent@example.invalid', message: 'Same intent', source: 'product', locale: 'en' };
  const selected = { productId: product.id, variantId: '', seriesId: family.id }, key = randomUUID();
  let entered!: () => void, resume!: () => void;
  const waiting = new Promise<void>(resolve => { entered = resolve; });
  const released = new Promise<void>(resolve => { resume = resolve; });
  const delayed = acceptInquiry(data, selected, key, async () => { entered(); await released; return true; });
  await waiting;
  const committed = await acceptInquiry(data, selected, key);
  await db.product.update({ where: { id: product.id }, data: { published: false } });
  resume(); assert.equal(await delayed, committed);
  assert.equal(await db.inquiry.count({ where: { submissionKey: key } }), 1);
});
test('media commit rechecks the current lease after file processing and creates nothing after revocation', async () => {
  const { assertCmsSessionInTransaction } = await import('../lib/auth');
  const actorId = randomUUID();
  const lease = await db.impPortalSession.create({ data: { id: randomUUID(), actorId, authSessionId: randomUUID(),
    displayName: 'Media editor', siteId: 'uten', permissions: '["website:view","website:media_manage"]', expiresAt: new Date(Date.now() + 60000) } });
  const session = { source: 'imp' as const, username: 'Media editor', actorId, portalSessionId: lease.id };
  await db.$transaction(tx => assertCmsSessionInTransaction(tx, session, 'website:media_manage'));
  await db.impPortalSession.update({ where: { id: lease.id }, data: { revokedAt: new Date() } });
  const before = await db.websiteDocumentAsset.count();
  await assert.rejects(db.$transaction(async tx => {
    await assertCmsSessionInTransaction(tx, session, 'website:media_manage');
    await tx.websiteDocumentAsset.create({ data: { storageKey: 'never-created.pdf', sha256: 'test', mimeType: 'application/pdf', originalName: 'test.pdf', sizeBytes: 1, createdBy: actorId } });
  }), /授权已过期/);
  assert.equal(await db.websiteDocumentAsset.count(), before);
});
