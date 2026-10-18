import { authorizeBridge, bridgeResponse, bridgeFailure } from '@/lib/imp-bridge-security';
import { pendingInquiries } from '@/lib/inquiry-delivery';
export const dynamic = 'force-dynamic';
export async function GET(request: Request) {
  try { authorizeBridge(request); return bridgeResponse({ items: await pendingInquiries(Number(new URL(request.url).searchParams.get('limit') || '20')) }); }
  catch (error) { return bridgeFailure(error); }
}
