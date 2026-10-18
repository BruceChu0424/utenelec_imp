import { boundedJson, requireSameOrigin, bridgeFailure, bridgeResponse } from '@/lib/imp-bridge-security';
import { consumePortalAuthorization } from '@/lib/imp-portal';
import { setPortalSession } from '@/lib/auth';
export async function POST(request: Request) {
  try {
    requireSameOrigin(request); const b = await boundedJson(request, 1024);
    const { session, destination } = await consumePortalAuthorization(b.code, b.verifier);
    await setPortalSession(session.id, session.displayName, session.expiresAt);
    return bridgeResponse({ destination });
  } catch (error) { return bridgeFailure(error); }
}
