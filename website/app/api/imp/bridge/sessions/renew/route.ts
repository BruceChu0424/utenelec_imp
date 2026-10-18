import { authorizeBridge, boundedJson, bridgeResponse, bridgeFailure } from '@/lib/imp-bridge-security';
import { renewPortalSessions } from '@/lib/imp-portal';
export async function POST(request: Request) {
  try { authorizeBridge(request); return bridgeResponse(await renewPortalSessions((await boundedJson(request)).items)); }
  catch (error) { return bridgeFailure(error); }
}
