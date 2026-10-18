import { authorizeBridge, boundedJson, bridgeResponse, bridgeFailure } from '@/lib/imp-bridge-security';
import { acknowledgeInquiries } from '@/lib/inquiry-delivery';
export async function POST(request: Request) {
  try { authorizeBridge(request); const body = await boundedJson(request); return bridgeResponse(await acknowledgeInquiries(body.items)); }
  catch (error) { return bridgeFailure(error); }
}
