import { createHash } from 'node:crypto';
import { persistInquiry, findInquiryReplay, type NewInquiry } from './inquiry-delivery';
import { resolveInquiryContext } from './inquiry-context';
import { INQUIRY_CONSENT_POLICY_VERSION } from './inquiry-security';
import { BridgeError } from './imp-bridge-security';

type ClientInquiry = Pick<NewInquiry, 'name' | 'phone' | 'email' | 'company' | 'market' | 'customerType' |
  'requiredStandard' | 'productInterest' | 'requestType' | 'estimatedQuantity' | 'targetSchedule' |
  'preferredContact' | 'message' | 'source'> & { locale: string };
export type InquirySelection = { productId: string; variantId: string; seriesId: string };
export function clientInquiryFingerprint(input: ClientInquiry, selection: InquirySelection) {
  // Only normalized client intent belongs to this fingerprint. Current product
  // names, versions and the server policy may change after the first acceptance.
  const canonical = Object.fromEntries(Object.entries({ ...input, ...selection, consent: true }).sort(([a], [b]) => a.localeCompare(b)));
  return createHash('sha256').update(JSON.stringify(canonical)).digest('hex');
}
export async function acceptInquiry(input: ClientInquiry, selection: InquirySelection, submissionKey: string, allowNew: () => boolean | Promise<boolean> = () => true) {
  const fingerprint = clientInquiryFingerprint(input, selection);
  const replay = await findInquiryReplay(submissionKey, fingerprint);
  if (replay) return replay;
  try {
    if (!await allowNew()) throw new BridgeError(429, 'INQUIRY_RATE_LIMIT');
    const form = new FormData(); for (const [key, value] of Object.entries(selection)) if (value) form.set(key, value);
    const sourceContext = await resolveInquiryContext(form, input.locale);
    return await persistInquiry({ ...input, submissionKey, sourceContext: JSON.stringify(sourceContext),
      consentAt: new Date(), consentPolicyVersion: INQUIRY_CONSENT_POLICY_VERSION }, fingerprint);
  } catch (error) {
    // Another identical request may have committed after our first lookup but
    // before current product validation or rate-limit completion.
    const committed = await findInquiryReplay(submissionKey, fingerprint);
    if (committed) return committed;
    throw error;
  }
}
