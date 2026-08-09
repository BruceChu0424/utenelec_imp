import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import bcrypt from 'bcryptjs';
import {
  localeOrMissing,
  mergeAdminI18n,
  mergeAdminProductSpecs,
  readAdminI18nLocale,
  readAdminProductSpecs,
  validateAdminEmail,
  validateAdminPhone,
  validateAdminPublicImagePath,
  validateAdminText,
} from '../lib/admin-i18n';
import {
  LoginRateLimiter,
  requireDestructiveSeedApproval,
  requireStrongAdminSeedPassword,
} from '../lib/admin-security';
import { requireStrongAuthSecret } from '../lib/auth-secret';
import {
  createSessionToken,
  resolveAdminClientIdentifier,
  verifyLoginPassword,
  verifySessionToken,
} from '../lib/auth';
import { getProductPublicationIssue, getSeriesPublicationIssue } from '../lib/publication';

const TEST_AUTH_SECRET = 'J7vQy2Ld8Ka4Zx9Nc6Ws3Pf1Hm5Rt0Bg7Eu4Yi2So8Dx';

test('CMS locale merge preserves unedited locales and fields', () => {
  const existing = JSON.stringify({
    zh: { name: '旧名称', description: '旧描述', internalNote: '保留' },
    en: { name: 'Old name', description: 'Old description' },
    fr: { name: 'Nom français' },
    ar: { name: 'اسم عربي' },
  });

  const merged = JSON.parse(mergeAdminI18n(existing, {
    zh: { name: '新名称', description: '' },
    en: { name: 'New name', description: '' },
  })) as Record<string, Record<string, string>>;

  assert.deepEqual(merged.fr, { name: 'Nom français' });
  assert.deepEqual(merged.ar, { name: 'اسم عربي' });
  assert.equal(merged.zh.name, '新名称');
  assert.equal(merged.zh.description, '');
  assert.equal(merged.zh.internalNote, '保留');
  assert.equal(merged.en.name, 'New name');
});

test('empty English locale stays missing instead of copying Chinese', () => {
  const english = localeOrMissing({ name: '', description: '   ' });
  assert.equal(english, null);

  const created = JSON.parse(mergeAdminI18n(null, {
    zh: { name: '中文名称' },
    en: english,
  })) as Record<string, unknown>;
  assert.deepEqual(created, { zh: { name: '中文名称' } });
  assert.equal(Object.prototype.hasOwnProperty.call(created, 'en'), false);
});

test('site setting merge supports localized arrays and preserves other locales', () => {
  const existing = JSON.stringify({
    zh: [{ value: '25+', label: '年行业深耕' }],
    en: [{ value: '25+', label: 'Years' }],
    fr: [{ value: '25+', label: 'Années' }],
  });
  const merged = JSON.parse(mergeAdminI18n(existing, {
    zh: [{ value: '26+', label: '年行业深耕' }],
    en: null,
  })) as Record<string, unknown>;

  assert.deepEqual(merged.zh, [{ value: '26+', label: '年行业深耕' }]);
  assert.equal(Object.prototype.hasOwnProperty.call(merged, 'en'), false);
  assert.deepEqual(merged.fr, [{ value: '25+', label: 'Années' }]);
});

test('malformed setting JSON fails closed instead of discarding hidden locales', () => {
  assert.throws(() => readAdminI18nLocale('{broken', 'zh'), /JSON/);
  assert.throws(() => mergeAdminI18n('{broken', { zh: { title: '新标题' } }), /JSON/);
  assert.throws(() => mergeAdminI18n('[]', { zh: { title: '新标题' } }), /按语言分组/);
});

test('site setting validators enforce length, contact formats and local image paths', () => {
  assert.equal(validateAdminText('  Uten  ', '标题', 20), 'Uten');
  assert.throws(() => validateAdminText('12345', '标题', 4), /4/);
  assert.equal(validateAdminEmail('sales@ch-uten.com', '邮箱'), 'sales@ch-uten.com');
  assert.throws(() => validateAdminEmail('not-an-email', '邮箱'), /格式/);
  assert.equal(validateAdminPhone('+86-760-22125999', '电话'), '+86-760-22125999');
  assert.throws(() => validateAdminPhone('call me', '电话'), /只能包含/);
  assert.equal(validateAdminPublicImagePath('/images/raw/factory.jpg', '图片'), '/images/raw/factory.jpg');
  assert.equal(validateAdminPublicImagePath('/uploads/about.webp', '图片'), '/uploads/about.webp');
  assert.throws(() => validateAdminPublicImagePath('https://example.com/a.jpg', '图片'), /站内图片/);
  assert.throws(() => validateAdminPublicImagePath('/images/../secret.jpg', '图片'), /站内图片/);
});

test('product specification merge promotes legacy arrays and preserves other locales', () => {
  const legacy = JSON.stringify([{ label: '额定电流', value: '10 A' }]);
  assert.deepEqual(readAdminProductSpecs(legacy, 'zh'), [{ label: '额定电流', value: '10 A' }]);
  assert.deepEqual(readAdminProductSpecs(legacy, 'en'), []);

  const localized = JSON.stringify({
    zh: [{ label: '旧参数', value: '旧值' }],
    en: [{ label: 'Old label', value: 'Old value' }],
    fr: [{ label: 'Courant nominal', value: '10 A' }],
  });
  const merged = JSON.parse(mergeAdminProductSpecs(localized, {
    zh: [{ label: '额定电流', value: '16 A' }],
    en: null,
  }) || '{}') as Record<string, unknown>;

  assert.deepEqual(merged.zh, [{ label: '额定电流', value: '16 A' }]);
  assert.equal(Object.prototype.hasOwnProperty.call(merged, 'en'), false);
  assert.deepEqual(merged.fr, [{ label: 'Courant nominal', value: '10 A' }]);
});

test('malformed product specifications fail closed instead of being silently discarded', () => {
  assert.throws(() => readAdminProductSpecs('{broken', 'zh'), /有效的 JSON/);
  assert.throws(
    () => readAdminProductSpecs(JSON.stringify({ zh: [{ label: '缺少值' }] }), 'zh'),
    /缺少 label 或 value/,
  );
  assert.throws(
    () => mergeAdminProductSpecs('{broken', { zh: [{ label: '电压', value: '250 V' }] }),
    /有效的 JSON/,
  );
});

test('login limiter blocks repeated account attempts and client rotation', () => {
  const limiter = new LoginRateLimiter({
    accountLimit: 2,
    clientLimit: 3,
    globalLimit: 20,
    windowMs: 1_000,
    blockMs: 2_000,
  });
  const now = 10_000;

  assert.equal(limiter.consume('client-a', 'Admin', now).allowed, true);
  assert.equal(limiter.consume('client-b', ' admin ', now + 1).allowed, true);
  assert.equal(limiter.consume('client-c', 'ADMIN', now + 2).allowed, false);

  assert.equal(limiter.consume('client-a', 'other-1', now + 3).allowed, true);
  assert.equal(limiter.consume('client-a', 'other-2', now + 4).allowed, true);
  assert.equal(limiter.consume('client-a', 'other-3', now + 5).allowed, false);
  assert.equal(limiter.consume('client-a', 'admin', now + 2_100).allowed, true);
});

test('admin login ignores client IP headers unless a trusted header is explicitly configured', () => {
  const values = new Map([
    ['x-forwarded-for', '198.51.100.9, 10.0.0.2'],
    ['cf-connecting-ip', '203.0.113.7'],
  ]);
  const getHeader = (name: string) => values.get(name) ?? null;

  assert.equal(resolveAdminClientIdentifier(getHeader, undefined), 'unknown');
  assert.equal(resolveAdminClientIdentifier(getHeader, 'x-forwarded-for'), '198.51.100.9');
  assert.equal(resolveAdminClientIdentifier(getHeader, 'cf-connecting-ip'), '203.0.113.7');
  assert.equal(resolveAdminClientIdentifier(getHeader, 'x-attacker-controlled-ip'), 'unknown');
});

test('seed password policy fails closed for missing, default and weak values', () => {
  assert.throws(() => requireStrongAdminSeedPassword(undefined), /ADMIN_PASSWORD 未配置/);
  assert.throws(() => requireStrongAdminSeedPassword('uten2024'), /过弱|默认值/);
  assert.throws(() => requireStrongAdminSeedPassword('onlylowercasepassword'), /至少应包含/);
  assert.equal(requireStrongAdminSeedPassword('Unique-Admin-2026!'), 'Unique-Admin-2026!');
});

test('destructive seed requires a separate exact opt-in', () => {
  assert.throws(() => requireDestructiveSeedApproval(undefined), /ALLOW_DESTRUCTIVE_SEED/);
  assert.throws(() => requireDestructiveSeedApproval('false'), /ALLOW_DESTRUCTIVE_SEED/);
  assert.throws(() => requireDestructiveSeedApproval('TRUE'), /ALLOW_DESTRUCTIVE_SEED/);
  assert.equal(requireDestructiveSeedApproval('true'), true);
});

test('AUTH_SECRET rejects missing, short, copied-example and low-entropy values', () => {
  assert.throws(() => requireStrongAuthSecret(undefined), /AUTH_SECRET/);
  assert.throws(() => requireStrongAuthSecret('short-secret'), /at least 43/);
  assert.throws(
    () => requireStrongAuthSecret('change-me-to-a-long-random-string-in-production'),
    /placeholder|weak/,
  );
  assert.throws(() => requireStrongAuthSecret('a'.repeat(64)), /placeholder|weak/);
  assert.equal(requireStrongAuthSecret(TEST_AUTH_SECRET), TEST_AUTH_SECRET);
});

test('password rotation immediately revokes previously issued administrator JWTs', async () => {
  const previousSecret = process.env.AUTH_SECRET;
  process.env.AUTH_SECRET = TEST_AUTH_SECRET;
  try {
    const oldPasswordHash = '$2b$12$old-password-hash-version';
    const newPasswordHash = '$2b$12$new-password-hash-version';
    const token = await createSessionToken('admin', oldPasswordHash);

    assert.deepEqual(await verifySessionToken(token, async () => oldPasswordHash), { username: 'admin' });
    assert.equal(await verifySessionToken(token, async () => newPasswordHash), null);
    assert.equal(await verifySessionToken(token, async () => null), null);
  } finally {
    if (previousSecret === undefined) delete process.env.AUTH_SECRET;
    else process.env.AUTH_SECRET = previousSecret;
  }
});

test('JWT signing and verification fail closed when AUTH_SECRET is unsafe', async () => {
  const previousSecret = process.env.AUTH_SECRET;
  const passwordHash = '$2b$12$current-password-hash-version';
  try {
    process.env.AUTH_SECRET = TEST_AUTH_SECRET;
    const token = await createSessionToken('admin', passwordHash);

    process.env.AUTH_SECRET = 'change-me-to-a-long-random-string-in-production';
    await assert.rejects(createSessionToken('admin', passwordHash), /AUTH_SECRET/);
    assert.equal(await verifySessionToken(token, async () => passwordHash), null);
  } finally {
    if (previousSecret === undefined) delete process.env.AUTH_SECRET;
    else process.env.AUTH_SECRET = previousSecret;
  }
});

test('legacy default password hashes are rejected while strong credentials still work', async () => {
  const legacyHash = await bcrypt.hash('uten2024', 4);
  const strongHash = await bcrypt.hash('Unique-Admin-2026!', 4);
  assert.equal(await verifyLoginPassword('uten2024', legacyHash), false);
  assert.equal(await verifyLoginPassword('Unique-Admin-2026!', strongHash), true);
  assert.equal(await verifyLoginPassword('not-the-password', undefined), false);
});

test('catalog publication requires a visible FAMILY hierarchy without blocking drafts', () => {
  const publishedFamily = { catalogRole: 'FAMILY', published: true, parent: null };
  const unpublishedFamily = { catalogRole: 'FAMILY', published: false, parent: null };
  const publishedCollection = { catalogRole: 'COLLECTION', published: true, parent: publishedFamily };

  assert.equal(getSeriesPublicationIssue(false, 'COLLECTION', null), null);
  assert.equal(getSeriesPublicationIssue(true, 'COLLECTION', null), 'collection-parent-required');
  assert.equal(
    getSeriesPublicationIssue(true, 'COLLECTION', unpublishedFamily),
    'collection-parent-required',
  );
  assert.equal(getSeriesPublicationIssue(true, 'COLLECTION', publishedFamily), null);
  assert.equal(getSeriesPublicationIssue(true, 'FAMILY', null), null);
  assert.equal(
    getSeriesPublicationIssue(false, 'FAMILY', null, { publishedProducts: 0, publishedCollections: 1 }),
    'published-collections-require-family',
  );
  assert.equal(
    getSeriesPublicationIssue(false, 'COLLECTION', publishedFamily, { publishedProducts: 1, publishedCollections: 0 }),
    'published-products-require-public-series',
  );
  assert.equal(
    getSeriesPublicationIssue(true, 'COLLECTION', publishedFamily, { publishedProducts: 1, publishedCollections: 0 }),
    null,
  );

  assert.equal(getProductPublicationIssue(false, null), null);
  assert.equal(getProductPublicationIssue(true, null), 'series-required');
  assert.equal(getProductPublicationIssue(true, unpublishedFamily), 'series-unpublished');
  assert.equal(getProductPublicationIssue(true, publishedFamily), null);
  assert.equal(getProductPublicationIssue(true, publishedCollection), null);
  assert.equal(
    getProductPublicationIssue(true, { catalogRole: 'COLLECTION', published: true, parent: null }),
    'collection-parent-required',
  );
  assert.equal(
    getProductPublicationIssue(true, { catalogRole: 'UNCLASSIFIED', published: true, parent: null }),
    'series-role-not-public',
  );
});

test('catalog admin mutations retain optimistic-lock, publication and hard-delete guards', async () => {
  const actionsPath = fileURLToPath(new URL('../app/admin/actions.ts', import.meta.url));
  const actions = await readFile(actionsPath, 'utf8');
  assert.match(actions, /where: \{ id, rowVersion: version as number \}/);
  assert.match(actions, /发布产品前必须选择一个已发布系列/);
  assert.match(actions, /至少需要一个已发布且有图片的款式/);
  assert.match(actions, /旧站合成占位，不得填写或伪装真实 SKU/);
  assert.match(actions, /unpublish-before-delete/);
  assert.match(actions, /series-not-empty/);
});
