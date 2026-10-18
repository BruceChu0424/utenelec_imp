import { randomBytes, randomUUID } from 'node:crypto';
import { prisma } from './db';
import { bridgeSiteId, BridgeError, CMS_PERMISSIONS, digest, fixedTimeEquals, PORTAL_SECTIONS } from './imp-bridge-security';

const text = (value: unknown, max: number) => typeof value === 'string' && value.length <= max ? value.trim() : '';
export async function registerPortalAuthorization(body: Record<string, unknown>, siteId: string) {
  const requestId = text(body.requestId, 80), actorId = text(body.actorId, 80);
  const authSessionId = text(body.authSessionId, 36);
  const displayName = text(body.displayName, 120), section = text(body.section, 30);
  const codeChallenge = text(body.codeChallenge, 43);
  const lease = new Date(String(body.expiresAt || ''));
  if (!/^[a-zA-Z0-9_-]{8,80}$/.test(requestId) || !actorId || !/^[0-9a-f-]{36}$/i.test(authSessionId) || !displayName || !PORTAL_SECTIONS[section]
    || !/^[a-zA-Z0-9_-]{43}$/.test(codeChallenge) || !Number.isFinite(lease.getTime())
    || lease.getTime() <= Date.now() || lease.getTime() > Date.now() + 5 * 60_000 + 2000) {
    throw new BridgeError(400, 'INVALID_AUTHORIZATION');
  }
  if (!Array.isArray(body.permissions) || !body.permissions.every(p => typeof p === 'string')) throw new BridgeError(400, 'INVALID_PERMISSIONS');
  const permissions = [...new Set(body.permissions.filter(p => CMS_PERMISSIONS.includes(p as typeof CMS_PERMISSIONS[number])))];
  if (!permissions.includes('website:view')) throw new BridgeError(403, 'WEBSITE_ACCESS_REQUIRED');
  const code = randomBytes(32).toString('base64url');
  const expiresAt = new Date(Math.min(Date.now() + 60_000, lease.getTime()));
  try {
    await prisma.impPortalAuthorization.create({ data: {
      requestId, actorId, authSessionId, displayName, employeeId: text(body.employeeId, 80) || null,
      permissions: JSON.stringify(permissions), section, codeChallenge, codeHash: digest(code), siteId,
      expiresAt, leaseExpiresAt: lease,
    } });
  } catch (error) {
    if (error && typeof error === 'object' && 'code' in error && error.code === 'P2002') throw new BridgeError(409, 'AUTHORIZATION_EXISTS');
    throw error;
  }
  return { code, expiresAt: expiresAt.toISOString() };
}
async function validAuthorization(code: unknown, verifier: unknown) {
  if (typeof code !== 'string' || !/^[a-zA-Z0-9_-]{43}$/.test(code)
    || typeof verifier !== 'string' || !/^[a-zA-Z0-9_-]{43,128}$/.test(verifier)) throw new BridgeError(400, 'INVALID_ENTRY');
  const authorization = await prisma.impPortalAuthorization.findUnique({ where: { codeHash: digest(code) } });
  if (!authorization || authorization.consumedAt || authorization.expiresAt.getTime() <= Date.now()
    || authorization.siteId !== bridgeSiteId() || !fixedTimeEquals(digest(verifier), authorization.codeChallenge)) {
    throw new BridgeError(401, 'ENTRY_EXPIRED');
  }
  return authorization;
}
export async function inspectPortalAuthorization(code: unknown, verifier: unknown) {
  const a = await validAuthorization(code, verifier);
  return { displayName: a.displayName, destination: PORTAL_SECTIONS[a.section], expiresAt: a.expiresAt };
}
export async function consumePortalAuthorization(code: unknown, verifier: unknown) {
  const a = await validAuthorization(code, verifier);
  return prisma.$transaction(async tx => {
    const consumed = await tx.impPortalAuthorization.updateMany({ where: {
      requestId: a.requestId, consumedAt: null, expiresAt: { gt: new Date() },
    }, data: { consumedAt: new Date() } });
    if (consumed.count !== 1) throw new BridgeError(409, 'ENTRY_ALREADY_USED');
    const session = await tx.impPortalSession.create({ data: {
      id: randomUUID(), actorId: a.actorId, authSessionId: a.authSessionId, employeeId: a.employeeId, displayName: a.displayName,
      permissions: a.permissions, siteId: a.siteId, expiresAt: a.leaseExpiresAt,
    } });
    await tx.cmsAuditEvent.create({ data: { actorId: a.actorId, action: 'portal_login',
      entityType: 'site', entityId: a.siteId, summary: '员工从 IMP 进入官网管理' } });
    return { session, destination: PORTAL_SECTIONS[a.section] };
  });
}
export async function revokePortalActor(actorId: unknown) {
  if (typeof actorId !== 'string' || !actorId || actorId.length > 80) throw new BridgeError(400, 'INVALID_ACTOR');
  return prisma.$transaction(async tx => {
    await tx.impPortalAuthorization.updateMany({ where: { actorId, siteId: bridgeSiteId(), consumedAt: null }, data: { consumedAt: new Date() } });
    const result = await tx.impPortalSession.updateMany({ where: { actorId, siteId: bridgeSiteId(), revokedAt: null }, data: { revokedAt: new Date() } });
    return { revoked: result.count };
  });
}

export async function activePortalSessions(after?: string, limit = 100) {
  const rows = await prisma.impPortalSession.findMany({ where: { siteId: bridgeSiteId(), revokedAt: null,
    expiresAt: { gt: new Date() }, createdAt: { gt: new Date(Date.now() - 8 * 60 * 60_000) },
    ...(after ? { id: { gt: after } } : {}) }, orderBy: { id: 'asc' }, take: Math.min(100, Math.max(1, limit)) + 1,
    select: { id: true, actorId: true, authSessionId: true } });
  const size = Math.min(100, Math.max(1, limit));
  return { items: rows.slice(0, size).map(r => ({ sessionId: r.id, actorId: r.actorId, authSessionId: r.authSessionId })),
    nextCursor: rows.length > size ? rows[size - 1].id : null };
}
export async function renewPortalSessions(items: unknown) {
  if (!Array.isArray(items) || items.length > 100) throw new BridgeError(400, 'INVALID_SESSION_LEASES');
  return prisma.$transaction(async tx => {
    let renewed = 0, revoked = 0, ignored = 0;
    for (const item of items) {
      if (!item || typeof item !== 'object' || typeof item.sessionId !== 'string' || typeof item.actorId !== 'string') throw new BridgeError(400, 'INVALID_SESSION_LEASE');
      const session = await tx.impPortalSession.findUnique({ where: { id: item.sessionId } });
      if (!session || session.siteId !== bridgeSiteId() || session.actorId !== item.actorId) throw new BridgeError(409, 'SESSION_ACTOR_MISMATCH');
      if (session.revokedAt || session.expiresAt.getTime() <= Date.now()) { ignored++; continue; }
      const allowed = Array.isArray(item.permissions)
        ? [...new Set(item.permissions.filter((p: unknown) => CMS_PERMISSIONS.includes(p as typeof CMS_PERMISSIONS[number])))] : [];
      if (item.revoked === true || !allowed.includes('website:view')) {
        await tx.impPortalSession.update({ where: { id: session.id }, data: { revokedAt: new Date() } }); revoked++; continue;
      }
      const expires = new Date(String(item.expiresAt || ''));
      const absolute = session.createdAt.getTime() + 8 * 60 * 60_000;
      if (!Number.isFinite(expires.getTime()) || expires.getTime() <= Date.now() || expires.getTime() > Date.now() + 302_000) throw new BridgeError(400, 'INVALID_LEASE_EXPIRY');
      if (absolute <= Date.now()) { await tx.impPortalSession.update({ where: { id: session.id }, data: { revokedAt: new Date() } }); revoked++; continue; }
      await tx.impPortalSession.update({ where: { id: session.id }, data: { expiresAt: new Date(Math.min(expires.getTime(), absolute)), permissions: JSON.stringify(allowed) } }); renewed++;
    }
    return { renewed, revoked, ignored };
  });
}
