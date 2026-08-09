import { isIP } from 'node:net';

export const INQUIRY_CONSENT_POLICY_VERSION = 'contact-consent-v1';

const TRUSTED_IP_HEADERS = new Set([
  'cf-connecting-ip',
  'fly-client-ip',
  'true-client-ip',
  'x-forwarded-for',
  'x-real-ip',
  'x-vercel-forwarded-for',
]);

export type InquiryRateLimitRule = {
  scope: 'client' | 'global';
  windowMs: number;
  max: number;
};

type RateLimiterOptions = {
  now?: () => number;
  rules?: InquiryRateLimitRule[];
};

type RateLimiterState = {
  buckets: Map<string, number[]>;
  lastCleanupAt: number;
};

const readPositiveInteger = (value: string | undefined, fallback: number, maximum: number) => {
  if (!value || !/^\d+$/.test(value)) return fallback;
  const parsed = Number(value);
  return parsed >= 1 && parsed <= maximum ? parsed : fallback;
};

export function inquiryRateLimitRules(
  environment: Record<string, string | undefined> = process.env,
): InquiryRateLimitRule[] {
  return [
    {
      scope: 'client',
      windowMs: 60_000,
      max: readPositiveInteger(environment.INQUIRY_RATE_CLIENT_MINUTE, 3, 100),
    },
    {
      scope: 'client',
      windowMs: 60 * 60_000,
      max: readPositiveInteger(environment.INQUIRY_RATE_CLIENT_HOUR, 15, 1_000),
    },
    {
      scope: 'global',
      windowMs: 60_000,
      max: readPositiveInteger(environment.INQUIRY_RATE_GLOBAL_MINUTE, 30, 10_000),
    },
    {
      scope: 'global',
      windowMs: 60 * 60_000,
      max: readPositiveInteger(environment.INQUIRY_RATE_GLOBAL_HOUR, 300, 100_000),
    },
  ];
}

function normalizeIp(value: string): string | null {
  let candidate = value.trim().replace(/^"|"$/g, '');
  if (candidate.startsWith('[')) {
    const closingBracket = candidate.indexOf(']');
    if (closingBracket > 0) candidate = candidate.slice(1, closingBracket);
  } else if (/^\d{1,3}(?:\.\d{1,3}){3}:\d+$/.test(candidate)) {
    candidate = candidate.slice(0, candidate.lastIndexOf(':'));
  }
  return isIP(candidate) ? candidate.toLowerCase() : null;
}

/**
 * Only reads a proxy header that deployment explicitly marks as trusted.
 * The proxy must overwrite this header and the application origin must not be
 * directly reachable, otherwise any forwarded client address is forgeable.
 */
export function resolveTrustedClientIp(
  getHeader: (name: string) => string | null,
  configuredHeader: string | undefined = process.env.INQUIRY_TRUSTED_CLIENT_IP_HEADER,
): string | null {
  const header = configuredHeader?.trim().toLowerCase();
  if (!header || !TRUSTED_IP_HEADERS.has(header)) return null;

  const rawValue = getHeader(header);
  if (!rawValue) return null;
  const candidate = header === 'x-forwarded-for' ? rawValue.split(',', 1)[0] : rawValue;
  return normalizeIp(candidate);
}

export function createInquiryRateLimiter({
  now = Date.now,
  rules = inquiryRateLimitRules(),
}: RateLimiterOptions = {}) {
  const state: RateLimiterState = { buckets: new Map(), lastCleanupAt: 0 };
  const longestWindow = Math.max(...rules.map((rule) => rule.windowMs));

  const cleanup = (currentTime: number) => {
    if (currentTime - state.lastCleanupAt < 60_000 && state.buckets.size < 1_000) return;
    for (const [key, timestamps] of state.buckets) {
      const live = timestamps.filter((timestamp) => timestamp > currentTime - longestWindow);
      if (live.length) state.buckets.set(key, live);
      else state.buckets.delete(key);
    }
    state.lastCleanupAt = currentTime;
  };

  return {
    allow(clientIp: string | null) {
      const currentTime = now();
      cleanup(currentTime);
      const clientKey = clientIp ?? 'unidentified-client';
      const pending: Array<{ key: string; timestamps: number[] }> = [];

      for (const rule of rules) {
        const subject = rule.scope === 'global' ? 'all' : clientKey;
        const key = `${rule.scope}:${subject}:${rule.windowMs}`;
        const cutoff = currentTime - rule.windowMs;
        const timestamps = (state.buckets.get(key) ?? []).filter((timestamp) => timestamp > cutoff);
        if (timestamps.length >= rule.max) return false;
        pending.push({ key, timestamps });
      }

      for (const bucket of pending) {
        bucket.timestamps.push(currentTime);
        state.buckets.set(bucket.key, bucket.timestamps);
      }
      return true;
    },
  };
}

type InquiryRateLimiter = ReturnType<typeof createInquiryRateLimiter>;

const globalForInquiryLimiter = globalThis as unknown as {
  utenInquiryRateLimiter?: InquiryRateLimiter;
};

export const inquiryRateLimiter =
  globalForInquiryLimiter.utenInquiryRateLimiter ?? createInquiryRateLimiter();

if (process.env.NODE_ENV !== 'test') {
  globalForInquiryLimiter.utenInquiryRateLimiter = inquiryRateLimiter;
}
