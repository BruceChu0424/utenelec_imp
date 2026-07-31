'use server';
import { prisma } from './db';
import { revalidatePath } from 'next/cache';

export async function submitInquiry(formData: FormData) {
  const name = String(formData.get('name') || '').trim();
  const phone = String(formData.get('phone') || '').trim() || null;
  const email = String(formData.get('email') || '').trim() || null;
  const company = String(formData.get('company') || '').trim() || null;
  const message = String(formData.get('message') || '').trim();
  const source = String(formData.get('source') || 'contact');
  if (!name || !message) return { ok: false, error: 'required' };
  try {
    await prisma.inquiry.create({ data: { name, phone, email, company, message, source } });
    revalidatePath('/admin/inquiries');
    return { ok: true };
  } catch {
    return { ok: false, error: 'server' };
  }
}
