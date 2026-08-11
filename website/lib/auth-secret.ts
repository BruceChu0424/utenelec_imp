const MIN_AUTH_SECRET_LENGTH = 43;

const REJECTED_NORMALIZED_VALUES = new Set([
  'changemetoalongrandomstringinproduction',
  'changemebeforeproduction',
  'changeme',
  'replacewithrandomsecret',
  'yourauthsecret',
  'yourjwtsecret',
  'developmentsecret',
  'productionsecret',
  'testsecret',
  'defaultsecret',
]);

const REJECTED_MARKERS = [
  'changeme',
  'replaceme',
  'placeholder',
  'randomstring',
  'password',
  'secret',
  'uten',
  'website',
  'company',
  'production',
  'development',
  'default',
  'example',
  'yoursecret',
  'authsecret',
  'jwtsecret',
  '0123456789',
  'abcdefghijklmnopqrstuvwxyz',
] as const;

/**
 * Fail closed on missing, copied-example, short, or obviously low-entropy JWT
 * secrets. A 32-byte random value encoded as base64 is 43-44 characters.
 */
export function requireStrongAuthSecret(value: string | undefined): string {
  if (!value) {
    throw new Error('AUTH_SECRET is not configured; refusing to start authentication');
  }
  if (value !== value.trim() || /\s/u.test(value)) {
    throw new Error('AUTH_SECRET must be a single random value without whitespace');
  }
  if (value.length < MIN_AUTH_SECRET_LENGTH) {
    throw new Error(`AUTH_SECRET must contain at least ${MIN_AUTH_SECRET_LENGTH} characters`);
  }

  const normalized = value.normalize('NFKC').toLocaleLowerCase().replace(/[^a-z0-9]/gu, '');
  const uniqueCharacters = new Set(value).size;
  const looksLikeRandomHex = /^[a-f0-9]{64,}$/iu.test(value);
  const looksLikeRandomBase64 = /^[a-z0-9+/_-]+={0,2}$/iu.test(value)
    && /[a-z]/u.test(value)
    && /[A-Z]/u.test(value)
    && /\d/u.test(value);
  if (
    REJECTED_NORMALIZED_VALUES.has(normalized)
    || REJECTED_MARKERS.some((marker) => normalized.includes(marker))
    || uniqueCharacters < 16
    || (!looksLikeRandomHex && !looksLikeRandomBase64)
  ) {
    throw new Error('AUTH_SECRET is a placeholder or predictably weak; use a cryptographically random value');
  }
  return value;
}

/** Called from Next.js instrumentation so an unsafe production process never serves requests. */
export function assertAuthRuntimeConfiguration(): void {
  requireStrongAuthSecret(process.env.AUTH_SECRET);
}
