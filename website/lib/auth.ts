import { SignJWT, jwtVerify } from 'jose';
import bcrypt from 'bcryptjs';
import { createHash, createHmac, timingSafeEqual } from 'node:crypto';
import { cookies, headers } from 'next/headers';
import { LoginRateLimiter } from './admin-security';
import { requireStrongAuthSecret } from './auth-secret';
import { resolveTrustedClientIp } from './inquiry-security';

const COOKIE_NAME = 'uten_admin_session';
const DUMMY_PASSWORD_HASH = '$2a$12$alZ8KYbq2bT.jLWevVvrT.WfzaHti.2tVSG1cWljhISyGb4Vm37ZO';
const KNOWN_DEFAULT_ADMIN_PASSWORDS = ['uten2024', 'change-me-before-first-seed'] as const;
const LOGIN_VERIFY_MINIMUM_MS = 800;
const KNOWN_DEFAULT_PASSWORD_DIGESTS = KNOWN_DEFAULT_ADMIN_PASSWORDS.map((password) =>
  createHash('sha256').update(password).digest(),
);

const globalAuthState = globalThis as typeof globalThis & {
  utenLoginRateLimiter?: LoginRateLimiter;
};

const loginRateLimiter = globalAuthState.utenLoginRateLimiter ?? new LoginRateLimiter();
globalAuthState.utenLoginRateLimiter = loginRateLimiter;

function getSecret(): Uint8Array {
  return new TextEncoder().encode(requireStrongAuthSecret(process.env.AUTH_SECRET));
}

function passwordVersionFingerprint(passwordHash: string): string {
  return createHmac('sha256', getSecret())
    .update('uten-admin-password-version-v1\0')
    .update(passwordHash)
    .digest('base64url');
}

function fingerprintsMatch(actual: unknown, expected: string): boolean {
  if (typeof actual !== 'string' || actual.length !== expected.length) return false;
  return timingSafeEqual(Buffer.from(actual, 'utf8'), Buffer.from(expected, 'utf8'));
}

export async function hashPassword(p: string): Promise<string> {
  return bcrypt.hash(p, 12);
}

export async function verifyPassword(plain: string, hash: string): Promise<boolean> {
  try {
    return await bcrypt.compare(plain, hash);
  } catch {
    return false;
  }
}

/**
 * Always run bcrypt, including for an unknown username, so the response does
 * not reveal whether an administrator account exists through a fast path.
 */
export async function verifyLoginPassword(plain: string, storedHash?: string): Promise<boolean> {
  const startedAt = Date.now();
  const passwordMatches = await verifyPassword(plain, storedHash || DUMMY_PASSWORD_HASH);
  const submittedDigest = createHash('sha256').update(plain).digest();
  const usesKnownDefaultPassword = KNOWN_DEFAULT_PASSWORD_DIGESTS.some((digest) =>
    timingSafeEqual(digest, submittedDigest),
  );

  // Keep unknown accounts, legacy cost-10 hashes, and current cost-12 hashes on
  // the same minimum response path. This masks both the DB lookup fast path and
  // historical bcrypt cost differences without weakening stored hashes.
  const remainingDelay = LOGIN_VERIFY_MINIMUM_MS - (Date.now() - startedAt);
  if (remainingDelay > 0) {
    await new Promise((resolve) => setTimeout(resolve, remainingDelay));
  }

  return passwordMatches && !usesKnownDefaultPassword;
}

export function resolveAdminClientIdentifier(
  getHeader: (name: string) => string | null,
  configuredHeader: string | undefined = process.env.ADMIN_TRUSTED_CLIENT_IP_HEADER,
): string {
  return resolveTrustedClientIp(getHeader, configuredHeader) ?? 'unknown';
}

export async function getLoginClientIdentifier(): Promise<string> {
  const requestHeaders = await headers();
  return resolveAdminClientIdentifier((name) => requestHeaders.get(name));
}

export function consumeLoginAttempt(clientIdentifier: string, username: string) {
  return loginRateLimiter.consume(clientIdentifier, username);
}

export function clearSuccessfulLoginAttempts(clientIdentifier: string, username: string) {
  loginRateLimiter.clearSuccessfulLogin(clientIdentifier, username);
}

export async function createSessionToken(username: string, passwordHash: string): Promise<string> {
  if (!username || !passwordHash) throw new Error('Cannot create an administrator session without current credentials');
  return new SignJWT({ username, passwordVersion: passwordVersionFingerprint(passwordHash) })
    .setProtectedHeader({ alg: 'HS256' })
    .setIssuer('uten-admin')
    .setAudience('uten-admin-cms')
    .setIssuedAt()
    .setExpirationTime('7d')
    .sign(getSecret());
}

type PasswordHashResolver = (username: string) => Promise<string | null>;

async function resolveCurrentPasswordHash(username: string): Promise<string | null> {
  const { prisma } = await import('./db');
  const user = await prisma.user.findUnique({ where: { username }, select: { password: true } });
  return user?.password ?? null;
}

export async function verifySessionToken(
  token: string,
  resolvePasswordHash: PasswordHashResolver = resolveCurrentPasswordHash,
): Promise<{ username: string } | null> {
  try {
    const { payload } = await jwtVerify(token, getSecret(), {
      algorithms: ['HS256'],
      issuer: 'uten-admin',
      audience: 'uten-admin-cms',
    });
    if (typeof payload.username !== 'string' || !payload.username) return null;
    const currentPasswordHash = await resolvePasswordHash(payload.username);
    if (!currentPasswordHash) return null;
    const expectedVersion = passwordVersionFingerprint(currentPasswordHash);
    if (!fingerprintsMatch(payload.passwordVersion, expectedVersion)) return null;
    return { username: payload.username };
  } catch {
    return null;
  }
}

export async function getSession() {
  const cookieStore = await cookies();
  const c = cookieStore.get(COOKIE_NAME)?.value;
  if (!c) return null;
  return verifySessionToken(c);
}

export async function setSession(username: string, passwordHash: string) {
  const token = await createSessionToken(username, passwordHash);
  const cookieStore = await cookies();
  cookieStore.set(COOKIE_NAME, token, {
    httpOnly: true,
    sameSite: 'lax',
    secure: process.env.NODE_ENV === 'production',
    path: '/',
    maxAge: 60 * 60 * 24 * 7,
  });
}

export async function clearSession() {
  const cookieStore = await cookies();
  cookieStore.delete(COOKIE_NAME);
}
