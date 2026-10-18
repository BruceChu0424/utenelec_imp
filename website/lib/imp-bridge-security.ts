import { createHash, timingSafeEqual } from 'node:crypto';

export class BridgeError extends Error {
  constructor(public status: number, public code: string) { super(code); }
}
export const CMS_PERMISSIONS = [
  'website:view', 'website:content_edit', 'website:product_edit', 'website:media_manage',
  'website:publish', 'website:rollback', 'webinquiry:view',
] as const;
export const PORTAL_SECTIONS: Record<string, string> = {
  overview: '/admin', home: '/admin/settings?setting=hero', content: '/admin/settings', settings: '/admin/settings',
  products: '/admin/products', series: '/admin/series', media: '/admin/media',
  resources: '/admin/resources', news: '/admin/news', cases: '/admin/cases',
  jobs: '/admin/jobs', scenes: '/admin/scenes', inquiries: '/admin/inquiries',
  releases: '/admin/releases',
};
export const digest = (value: string) => createHash('sha256').update(value).digest('base64url');
export function fixedTimeEquals(left: string, right: string): boolean {
  return timingSafeEqual(createHash('sha256').update(left).digest(), createHash('sha256').update(right).digest());
}
export function bridgeSiteId(): string { return process.env.WEB_SITE_ID?.trim() || 'uten'; }
export function isBridgeTokenConfigured(token: string | undefined): boolean {
  return typeof token === 'string' && /^[A-Za-z0-9+/=_-]{43,512}$/.test(token);
}
export function authorizeBridge(request: Request): string {
  const token = process.env.UTEN_WEBSITE_BRIDGE_TOKEN;
  if (!isBridgeTokenConfigured(token)) throw new BridgeError(503, 'BRIDGE_NOT_CONFIGURED');
  const supplied = request.headers.get('authorization') || '';
  if (!supplied.startsWith('Bearer ') || !fixedTimeEquals(supplied.slice(7), token as string)) {
    throw new BridgeError(401, 'UNAUTHORIZED');
  }
  const siteId = bridgeSiteId();
  if (request.headers.get('x-uten-site-id') !== siteId) throw new BridgeError(403, 'SITE_MISMATCH');
  return siteId;
}
export function requireSameOrigin(request: Request): void {
  const expected = process.env.SITE_URL;
  const origin = request.headers.get('origin');
  if (!expected || !origin || new URL(expected).origin !== origin) throw new BridgeError(403, 'ORIGIN_MISMATCH');
  if (request.headers.get('sec-fetch-site') === 'cross-site') throw new BridgeError(403, 'CROSS_SITE_REQUEST');
}
export async function boundedJson(request: Request, maximum = 64 * 1024): Promise<Record<string, unknown>> {
  if (!request.headers.get('content-type')?.startsWith('application/json')) throw new BridgeError(415, 'JSON_REQUIRED');
  const declared = Number(request.headers.get('content-length') || '0');
  if (!Number.isFinite(declared) || declared > maximum) throw new BridgeError(413, 'BODY_TOO_LARGE');
  const reader = request.body?.getReader();
  if (!reader) throw new BridgeError(400, 'BODY_REQUIRED');
  let bytes = 0; const chunks: Uint8Array[] = [];
  while (true) {
    const part = await reader.read(); if (part.done) break;
    bytes += part.value.length;
    if (bytes > maximum) { await reader.cancel(); throw new BridgeError(413, 'BODY_TOO_LARGE'); }
    chunks.push(part.value);
  }
  try {
    const value: unknown = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error();
    return value as Record<string, unknown>;
  } catch { throw new BridgeError(400, 'INVALID_JSON'); }
}
export function bridgeResponse(value: unknown, status = 200): Response {
  return Response.json(value, { status, headers: { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' } });
}
export function bridgeFailure(error: unknown): Response {
  if (error instanceof BridgeError) return bridgeResponse({ error: error.code }, error.status);
  // Database/transport details and contact payloads never leave this boundary.
  return bridgeResponse({ error: 'SERVICE_UNAVAILABLE' }, 503);
}
