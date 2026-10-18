import { authorizeBridge, bridgeResponse, bridgeFailure } from '@/lib/imp-bridge-security';
import { activePortalSessions } from '@/lib/imp-portal';
export const dynamic = 'force-dynamic';
export async function GET(request: Request) {
  try { authorizeBridge(request); const query = new URL(request.url).searchParams;
    return bridgeResponse(await activePortalSessions(query.get('after') || undefined, Number(query.get('limit') || 100) || 100)); }
  catch (error) { return bridgeFailure(error); }
}
