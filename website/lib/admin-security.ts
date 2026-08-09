import { createHash } from 'node:crypto';

const DEFAULT_WINDOW_MS = 15 * 60 * 1000;
const DEFAULT_BLOCK_MS = 15 * 60 * 1000;

type AttemptBucket = {
  attempts: number[];
  blockedUntil: number;
};

export type LoginRateLimitResult = {
  allowed: boolean;
  retryAfterSeconds: number;
};

type LoginRateLimiterOptions = {
  accountLimit?: number;
  clientLimit?: number;
  globalLimit?: number;
  windowMs?: number;
  blockMs?: number;
  maxBuckets?: number;
};

/**
 * Process-local login limiter. It deliberately limits both the submitted
 * account identifier and the client fingerprint, so changing either one does
 * not provide an unlimited password-guessing path.
 */
export class LoginRateLimiter {
  private readonly buckets = new Map<string, AttemptBucket>();
  private readonly accountLimit: number;
  private readonly clientLimit: number;
  private readonly globalLimit: number;
  private readonly windowMs: number;
  private readonly blockMs: number;
  private readonly maxBuckets: number;
  private consumeCount = 0;

  constructor(options: LoginRateLimiterOptions = {}) {
    this.accountLimit = options.accountLimit ?? 5;
    this.clientLimit = options.clientLimit ?? 20;
    this.globalLimit = options.globalLimit ?? 200;
    this.windowMs = options.windowMs ?? DEFAULT_WINDOW_MS;
    this.blockMs = options.blockMs ?? DEFAULT_BLOCK_MS;
    this.maxBuckets = options.maxBuckets ?? 10_000;
  }

  consume(clientIdentifier: string, username: string, now = Date.now()): LoginRateLimitResult {
    this.consumeCount += 1;
    if (this.consumeCount % 100 === 0) this.prune(now);

    const accountKey = `account:${fingerprint(normalizeUsername(username))}`;
    const clientKey = `client:${fingerprint(clientIdentifier || 'unknown')}`;
    const results = [
      this.consumeBucket(accountKey, this.accountLimit, now),
      this.consumeBucket(clientKey, this.clientLimit, now),
      this.consumeBucket('global', this.globalLimit, now),
    ];
    this.enforceBucketLimit();

    const blocked = results.filter((result) => !result.allowed);
    return blocked.length
      ? { allowed: false, retryAfterSeconds: Math.max(...blocked.map((result) => result.retryAfterSeconds)) }
      : { allowed: true, retryAfterSeconds: 0 };
  }

  clearSuccessfulLogin(clientIdentifier: string, username: string): void {
    this.buckets.delete(`account:${fingerprint(normalizeUsername(username))}`);
    this.buckets.delete(`client:${fingerprint(clientIdentifier || 'unknown')}`);
  }

  private consumeBucket(key: string, limit: number, now: number): LoginRateLimitResult {
    const bucket = this.buckets.get(key) ?? { attempts: [], blockedUntil: 0 };
    if (bucket.blockedUntil > now) {
      return {
        allowed: false,
        retryAfterSeconds: Math.max(1, Math.ceil((bucket.blockedUntil - now) / 1000)),
      };
    }

    bucket.attempts = bucket.attempts.filter((attempt) => attempt > now - this.windowMs);
    bucket.blockedUntil = 0;
    if (bucket.attempts.length >= limit) {
      bucket.blockedUntil = now + this.blockMs;
      this.buckets.set(key, bucket);
      return { allowed: false, retryAfterSeconds: Math.ceil(this.blockMs / 1000) };
    }

    bucket.attempts.push(now);
    this.buckets.set(key, bucket);
    return { allowed: true, retryAfterSeconds: 0 };
  }

  private prune(now: number): void {
    for (const [key, bucket] of this.buckets) {
      const newestAttempt = bucket.attempts[bucket.attempts.length - 1] ?? 0;
      if (bucket.blockedUntil <= now && newestAttempt <= now - this.windowMs) this.buckets.delete(key);
    }
  }

  private enforceBucketLimit(): void {
    if (this.buckets.size <= this.maxBuckets) return;
    for (const key of this.buckets.keys()) {
      if (this.buckets.size <= this.maxBuckets) break;
      if (key !== 'global') this.buckets.delete(key);
    }
  }
}

function normalizeUsername(username: string): string {
  return username.trim().normalize('NFKC').toLocaleLowerCase().slice(0, 128);
}

function fingerprint(value: string): string {
  return createHash('sha256').update(value.slice(0, 512)).digest('hex');
}

const rejectedPasswords = new Set([
  'admin',
  'admin123',
  'password',
  'password123',
  'qwerty',
  '123456',
  'uten2024',
  'changemebeforefirstseed',
  'changemetoalongrandomstringinproduction',
]);

/** Require a separate, explicit opt-in before the legacy seed may delete data. */
export function requireDestructiveSeedApproval(value: string | undefined): true {
  if (value !== 'true') {
    throw new Error('ALLOW_DESTRUCTIVE_SEED must be exactly "true" before the destructive seed can run');
  }
  return true;
}

/** Validate the destructive seed's administrator password before any writes. */
export function requireStrongAdminSeedPassword(value: string | undefined): string {
  if (!value) {
    throw new Error('ADMIN_PASSWORD 未配置；seed 已在写入数据库前终止');
  }
  if (value !== value.trim()) {
    throw new Error('ADMIN_PASSWORD 首尾不能包含空格');
  }

  const normalized = value.toLocaleLowerCase().replace(/[^a-z0-9]/g, '');
  if (value.length < 14 || rejectedPasswords.has(normalized)) {
    throw new Error('ADMIN_PASSWORD 过弱或仍是默认值；请使用至少 14 位的唯一强密码');
  }

  const characterClasses = [/[a-z]/.test(value), /[A-Z]/.test(value), /\d/.test(value), /[^A-Za-z0-9]/.test(value)]
    .filter(Boolean).length;
  if (characterClasses < 3) {
    throw new Error('ADMIN_PASSWORD 过弱；至少应包含大小写字母、数字、符号中的三类');
  }
  return value;
}
