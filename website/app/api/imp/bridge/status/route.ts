import { prisma } from '@/lib/db';
import { authorizeBridge, bridgeResponse, bridgeFailure } from '@/lib/imp-bridge-security';
export const dynamic = 'force-dynamic';
export async function GET(request: Request) {
  try {
    const siteId = authorizeBridge(request);
    const [pendingInquiries, oldest, last, revision] = await Promise.all([
      prisma.inquiryDelivery.count({ where: { state: 'PENDING' } }),
      prisma.inquiryDelivery.findFirst({ where: { state: 'PENDING' }, orderBy: { createdAt: 'asc' }, select: { createdAt: true } }),
      prisma.inquiryDelivery.findFirst({ where: { state: 'ACKNOWLEDGED' }, orderBy: { acknowledgedAt: 'desc' }, select: { acknowledgedAt: true } }),
      prisma.cmsRevision.findFirst({ where: { status: 'PUBLISHED' }, orderBy: { publishedAt: 'desc' }, select: { id: true } }),
    ]);
    return bridgeResponse({ siteId, ready: true, publishedRevision: revision?.id ?? null,
      pendingInquiries, oldestPendingAt: oldest?.createdAt ?? null, lastDeliveryAt: last?.acknowledgedAt ?? null });
  } catch (error) { return bridgeFailure(error); }
}
