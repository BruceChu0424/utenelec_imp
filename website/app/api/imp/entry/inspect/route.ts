import { boundedJson, requireSameOrigin, bridgeFailure, bridgeResponse } from '@/lib/imp-bridge-security';
import { inspectPortalAuthorization } from '@/lib/imp-portal';
export async function POST(request: Request) {
  try { requireSameOrigin(request); const b = await boundedJson(request, 1024); return bridgeResponse(await inspectPortalAuthorization(b.code, b.verifier)); }
  catch (error) { return bridgeFailure(error); }
}
