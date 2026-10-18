import { getSession, setPortalSession } from '@/lib/auth';
import { requireSameOrigin, BridgeError, bridgeFailure, bridgeResponse } from '@/lib/imp-bridge-security';
export async function POST(request: Request) {
  try {
    requireSameOrigin(request); const session = await getSession();
    if (!session?.portalSessionId || !session.expiresAt) throw new BridgeError(401, 'SESSION_EXPIRED');
    await setPortalSession(session.portalSessionId, session.username, session.expiresAt);
    return bridgeResponse({ expiresAt: session.expiresAt, permissions: session.permissions });
  } catch (error) { return bridgeFailure(error); }
}
