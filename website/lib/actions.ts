'use server';

import { revalidatePath } from 'next/cache';
import { headers } from 'next/headers';
import { routing } from '@/i18n/routing';
import { prisma } from './db';
import {
  INQUIRY_CONSENT_POLICY_VERSION,
  inquiryRateLimiter,
  resolveTrustedClientIp,
} from './inquiry-security';

const SOURCES = new Set(['contact', 'join', 'partner', 'product', 'studio']);
const CUSTOMER_TYPES = new Set(['distributor', 'project', 'oem', 'designer', 'other']);
const REQUEST_TYPES = new Set(['quotation', 'sample', 'technical', 'partnership', 'other']);
const LOCALES = new Set<string>(routing.locales);
const clean = (value: FormDataEntryValue | null, max: number) => String(value || '').trim().slice(0, max);

const rejected = (reason?: 'contact-required') => reason
  ? { ok: false as const, reason }
  : { ok: false as const };

export async function submitInquiry(formData: FormData) {
  if (clean(formData.get('website'), 200)) return { ok: true as const };
  const name = clean(formData.get('name'), 80);
  const phone = clean(formData.get('phone'), 40) || null;
  const email = clean(formData.get('email'), 160) || null;
  const company = clean(formData.get('company'), 160) || null;
  const market = clean(formData.get('market'), 120) || null;
  const rawCustomerType = clean(formData.get('customerType'), 32);
  const customerType = CUSTOMER_TYPES.has(rawCustomerType) ? rawCustomerType : null;
  const requiredStandard = clean(formData.get('requiredStandard'), 160) || null;
  const productInterest = clean(formData.get('productInterest'), 240) || null;
  const rawRequestType = clean(formData.get('requestType'), 32);
  const requestType = REQUEST_TYPES.has(rawRequestType) ? rawRequestType : null;
  const estimatedQuantity = clean(formData.get('estimatedQuantity'), 120) || null;
  const targetSchedule = clean(formData.get('targetSchedule'), 120) || null;
  const preferredContact = clean(formData.get('preferredContact'), 80) || null;
  const message = clean(formData.get('message'), 3000);
  const rawSource = clean(formData.get('source'), 24);
  const source = SOURCES.has(rawSource) ? rawSource : 'contact';
  const locale = clean(formData.get('locale'), 8);
  const consent = formData.get('consent') === 'yes';

  if (!phone && !email) return rejected('contact-required');
  if (!name || !message || !consent || !LOCALES.has(locale)) return rejected();
  if (source === 'partner' && (!market || !customerType || !productInterest || !requestType)) return rejected();
  if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return rejected();

  const requestHeaders = await headers();
  const clientIp = resolveTrustedClientIp((header) => requestHeaders.get(header));
  if (!inquiryRateLimiter.allow(clientIp)) return rejected();

  try {
    const inquiry = await prisma.inquiry.create({
      data: {
        name,
        phone,
        email,
        company,
        market,
        customerType,
        requiredStandard,
        productInterest,
        requestType,
        estimatedQuantity,
        targetSchedule,
        preferredContact,
        message,
        source,
        locale,
        consentAt: new Date(),
        consentPolicyVersion: INQUIRY_CONSENT_POLICY_VERSION,
      },
    });
    revalidatePath('/admin/inquiries');
    forwardInquiryToImp({
      sourceId: inquiry.id,
      name,
      phone,
      email,
      company,
      market,
      customerType,
      requiredStandard,
      productInterest,
      requestType,
      estimatedQuantity,
      targetSchedule,
      preferredContact,
      message,
      source,
      locale,
    });
    return { ok: true as const };
  } catch {
    return rejected();
  }
}

type ImpInquiryPayload = {
  sourceId: string;
  name: string;
  phone: string | null;
  email: string | null;
  company: string | null;
  market: string | null;
  customerType: string | null;
  requiredStandard: string | null;
  productInterest: string | null;
  requestType: string | null;
  estimatedQuantity: string | null;
  targetSchedule: string | null;
  preferredContact: string | null;
  message: string;
  source: string;
  locale: string;
};

/**
 * 询盘同步推送到 IMP 平台（销售统一工作台，POST /api/website-inquiries/ingest）。
 * 刻意 fire-and-forget：官网落库即成功，推送失败只记日志、由 IMP 侧缺单巡检兜底，
 * 绝不让内部系统抖动影响对外表单转化。未配置 IMP_INGEST_URL/TOKEN 时静默跳过。
 */
function forwardInquiryToImp(payload: ImpInquiryPayload) {
  const url = process.env.IMP_INGEST_URL;
  const token = process.env.IMP_INGEST_TOKEN;
  if (!url || !token) return;
  fetch(url, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-uten-ingest-token': token,
    },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(4000),
  })
    .then(async (response) => {
      if (!response.ok) {
        console.warn(`[inquiry] IMP ingest rejected ${response.status} for ${payload.sourceId}`);
      }
    })
    .catch((error: unknown) => {
      console.warn(`[inquiry] IMP ingest failed for ${payload.sourceId}:`, error);
    });
}
