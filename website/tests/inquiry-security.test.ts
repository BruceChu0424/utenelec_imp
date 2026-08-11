import assert from 'node:assert/strict';
import test from 'node:test';
import {
  createInquiryRateLimiter,
  inquiryRateLimitRules,
  resolveTrustedClientIp,
  type InquiryRateLimitRule,
} from '../lib/inquiry-security';
import { submitInquiry } from '../lib/actions';

test('trusted client IP is read only from an explicitly allowed proxy header', () => {
  const headers = new Map([
    ['x-forwarded-for', '198.51.100.10, 10.0.0.4'],
    ['x-real-ip', '203.0.113.7'],
  ]);
  const getHeader = (name: string) => headers.get(name) ?? null;

  assert.equal(resolveTrustedClientIp(getHeader, undefined), null);
  assert.equal(resolveTrustedClientIp(getHeader, 'authorization'), null);
  assert.equal(resolveTrustedClientIp(getHeader, 'x-forwarded-for'), '198.51.100.10');
  assert.equal(resolveTrustedClientIp(getHeader, 'x-real-ip'), '203.0.113.7');
});

test('invalid, missing and ambiguous client addresses fail closed', () => {
  assert.equal(resolveTrustedClientIp(() => 'not-an-ip', 'x-real-ip'), null);
  assert.equal(resolveTrustedClientIp(() => null, 'x-real-ip'), null);
  assert.equal(resolveTrustedClientIp(() => '192.0.2.8:443', 'x-real-ip'), '192.0.2.8');
  assert.equal(resolveTrustedClientIp(() => '[2001:db8::1]:443', 'x-real-ip'), '2001:db8::1');
});

test('client minute and hour limits are both enforced', () => {
  let currentTime = 1_000_000;
  const rules: InquiryRateLimitRule[] = [
    { scope: 'client', windowMs: 60_000, max: 2 },
    { scope: 'client', windowMs: 3_600_000, max: 3 },
    { scope: 'global', windowMs: 60_000, max: 100 },
    { scope: 'global', windowMs: 3_600_000, max: 100 },
  ];
  const limiter = createInquiryRateLimiter({ now: () => currentTime, rules });

  assert.equal(limiter.allow('192.0.2.1'), true);
  assert.equal(limiter.allow('192.0.2.1'), true);
  assert.equal(limiter.allow('192.0.2.1'), false, 'minute limit');
  currentTime += 60_001;
  assert.equal(limiter.allow('192.0.2.1'), true);
  currentTime += 60_001;
  assert.equal(limiter.allow('192.0.2.1'), false, 'hour limit');
  assert.equal(limiter.allow('192.0.2.2'), true, 'client buckets are independent');
});

test('global minute and hour limits cover rotating client addresses', () => {
  let currentTime = 2_000_000;
  const minuteLimiter = createInquiryRateLimiter({
    now: () => currentTime,
    rules: [
      { scope: 'client', windowMs: 60_000, max: 100 },
      { scope: 'client', windowMs: 3_600_000, max: 100 },
      { scope: 'global', windowMs: 60_000, max: 2 },
      { scope: 'global', windowMs: 3_600_000, max: 100 },
    ],
  });
  assert.equal(minuteLimiter.allow('192.0.2.1'), true);
  assert.equal(minuteLimiter.allow('192.0.2.2'), true);
  assert.equal(minuteLimiter.allow('192.0.2.3'), false);

  const hourLimiter = createInquiryRateLimiter({
    now: () => currentTime,
    rules: [
      { scope: 'client', windowMs: 60_000, max: 100 },
      { scope: 'client', windowMs: 3_600_000, max: 100 },
      { scope: 'global', windowMs: 60_000, max: 100 },
      { scope: 'global', windowMs: 3_600_000, max: 2 },
    ],
  });
  assert.equal(hourLimiter.allow('192.0.2.1'), true);
  currentTime += 60_001;
  assert.equal(hourLimiter.allow('192.0.2.2'), true);
  currentTime += 60_001;
  assert.equal(hourLimiter.allow('192.0.2.3'), false);
});

test('invalid rate limit environment values retain safe defaults', () => {
  const rules = inquiryRateLimitRules({
    INQUIRY_RATE_CLIENT_MINUTE: '0',
    INQUIRY_RATE_CLIENT_HOUR: 'not-a-number',
    INQUIRY_RATE_GLOBAL_MINUTE: '10001',
    INQUIRY_RATE_GLOBAL_HOUR: '-1',
  });
  assert.deepEqual(rules.map((rule) => rule.max), [3, 15, 30, 300]);
});

test('international partnership enquiries require a complete routing brief', async () => {
  const incomplete = new FormData();
  incomplete.set('name', 'International test');
  incomplete.set('email', 'buyer@example.com');
  incomplete.set('message', 'Please review this project.');
  incomplete.set('source', 'partner');
  incomplete.set('locale', 'en');
  incomplete.set('consent', 'yes');
  assert.deepEqual(await submitInquiry(incomplete), { ok: false });

  incomplete.set('market', 'United Kingdom');
  incomplete.set('customerType', 'untrusted-value');
  incomplete.set('productInterest', 'S300 switching functions');
  incomplete.set('requestType', 'technical');
  assert.deepEqual(await submitInquiry(incomplete), { ok: false });
});
