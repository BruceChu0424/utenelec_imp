import { authorizeBridge, boundedJson, bridgeFailure, bridgeResponse } from '@/lib/imp-bridge-security';
import { revokePortalActor } from '@/lib/imp-portal';
export async function POST(request: Request) {
  try { authorizeBridge(request); return bridgeResponse(await revokePortalActor((await boundedJson(request, 1024)).actorId)); }
  catch (error) { return bridgeFailure(error); }
}
