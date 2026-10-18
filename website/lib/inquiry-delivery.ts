import { createHash } from 'node:crypto';
import { prisma } from './db';
import { BridgeError } from './imp-bridge-security';
import type { Prisma } from '@prisma/client';

export type NewInquiry = Omit<Prisma.InquiryUncheckedCreateInput, 'id' | 'createdAt' | 'delivery'>;
export function inquiryFingerprint(input: NewInquiry): string {
  const { consentAt: _consentAt, submissionKey: _key, submissionFingerprint: _fingerprint, ...stable } = input;
  // Source-context consent time is assigned separately in the exported payload.
  return createHash('sha256').update(JSON.stringify(Object.fromEntries(Object.entries(stable).sort(([a], [b]) => a.localeCompare(b))))).digest('hex');
}
export async function findInquiryReplay(submissionKey: string, fingerprint: string) {
  const existing = await prisma.inquiry.findUnique({ where: { submissionKey } });
  if (existing && existing.submissionFingerprint !== fingerprint) throw new BridgeError(409, 'SUBMISSION_CHANGED');
  return existing?.id ?? null;
}
export async function persistInquiry(input: NewInquiry, requestFingerprint = inquiryFingerprint(input)) {
  const fingerprint = requestFingerprint;
  const getReplay = async () => {
    const existing = input.submissionKey ? await prisma.inquiry.findUnique({ where: { submissionKey: input.submissionKey } }) : null;
    if (existing && existing.submissionFingerprint !== fingerprint) throw new BridgeError(409, 'SUBMISSION_CHANGED');
    return existing;
  };
  const replay = await getReplay();
  if (replay) return replay.id;
  try {
    const result = await prisma.$transaction(async tx => tx.inquiry.create({ data: {
      ...input, submissionFingerprint: fingerprint, delivery: { create: {} },
    }, select: { id: true } }));
    return result.id;
  } catch (error) {
    // The unique submission key serializes duplicate requests, including a
    // client retry after a timeout that occurred after the first commit.
    const committed = await getReplay();
    if (committed) return committed.id;
    throw error;
  }
}
export async function pendingInquiries(limit: number) {
  const rows = await prisma.inquiryDelivery.findMany({
    where: { state: 'PENDING' }, orderBy: [{ createdAt: 'asc' }, { id: 'asc' }],
    take: Math.min(50, Math.max(1, Math.trunc(limit) || 20)), include: { inquiry: true },
  });
  return rows.map(({ id, inquiry: i }) => ({
    deliveryId: id, sourceId: i.id, name: i.name, phone: i.phone, email: i.email,
    company: i.company, market: i.market, customerType: i.customerType,
    requiredStandard: i.requiredStandard, productInterest: i.productInterest,
    requestType: i.requestType, estimatedQuantity: i.estimatedQuantity,
    targetSchedule: i.targetSchedule, preferredContact: i.preferredContact,
    message: i.message, source: i.source, locale: i.locale,
    sourceContext: {
      ...(i.sourceContext ? JSON.parse(i.sourceContext) : {}),
      consentAt: i.consentAt?.toISOString(), consentPolicyVersion: i.consentPolicyVersion,
    },
  }));
}
export async function acknowledgeInquiries(items: unknown) {
  if (!Array.isArray(items) || items.length < 1 || items.length > 50) throw new BridgeError(400, 'INVALID_RECEIPTS');
  const receipts = items.map(item => {
    if (!item || typeof item !== 'object') throw new BridgeError(400, 'INVALID_RECEIPT');
    const { deliveryId, sourceId, erpInquiryId } = item;
    if (![deliveryId, sourceId, erpInquiryId].every(x => typeof x === 'string' && /^[a-zA-Z0-9_-]{1,80}$/.test(x))) {
      throw new BridgeError(400, 'INVALID_RECEIPT');
    }
    return { deliveryId, sourceId, erpInquiryId } as { deliveryId: string; sourceId: string; erpInquiryId: string };
  });
  return prisma.$transaction(async tx => {
    for (const receipt of receipts) {
      const current = await tx.inquiryDelivery.findUnique({ where: { id: receipt.deliveryId } });
      if (!current || current.inquiryId !== receipt.sourceId) throw new BridgeError(409, 'RECEIPT_MISMATCH');
      if (current.state === 'ACKNOWLEDGED') {
        if (current.erpInquiryId !== receipt.erpInquiryId) throw new BridgeError(409, 'RECEIPT_MISMATCH');
        continue;
      }
      const updated = await tx.inquiryDelivery.updateMany({ where: { id: receipt.deliveryId, state: 'PENDING' },
        data: { state: 'ACKNOWLEDGED', erpInquiryId: receipt.erpInquiryId, acknowledgedAt: new Date() } });
      if (updated.count !== 1) throw new BridgeError(409, 'RECEIPT_CHANGED');
    }
    return { acknowledged: receipts.length };
  });
}
