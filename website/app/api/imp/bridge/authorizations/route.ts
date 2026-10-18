import { authorizeBridge, boundedJson, bridgeFailure, bridgeResponse } from '@/lib/imp-bridge-security';
import { registerPortalAuthorization } from '@/lib/imp-portal';
export async function POST(request: Request) {
  try { const siteId = authorizeBridge(request); return bridgeResponse(await registerPortalAuthorization(await boundedJson(request, 8192), siteId)); }
  catch (error) { return bridgeFailure(error); }
}
