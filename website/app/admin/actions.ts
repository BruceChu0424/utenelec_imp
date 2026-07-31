'use server';
import { prisma } from '@/lib/db';
import { setSession, clearSession, verifyPassword } from '@/lib/auth';
import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import * as fs from 'fs/promises';
import * as path from 'path';

/* ============ 认证 ============ */
export async function login(formData: FormData) {
  const username = String(formData.get('username') || '').trim();
  const password = String(formData.get('password') || '');
  const user = await prisma.user.findUnique({ where: { username } });
  if (!user || !(await verifyPassword(password, user.password))) {
    return { error: '用户名或密码错误' };
  }
  await setSession(username);
  redirect('/admin');
}

export async function logout() {
  clearSession();
  redirect('/admin/login');
}

/* ============ 图片上传 (本地 public/uploads) ============ */
export async function uploadImage(formData: FormData): Promise<{ url?: string; error?: string }> {
  const s = await getSessionSafe();
  if (!s) return { error: '未登录' };
  const file = formData.get('file');
  if (!(file instanceof File)) return { error: '未选择文件' };
  if (file.size > 8 * 1024 * 1024) return { error: '文件超过 8MB' };
  const buf = Buffer.from(await file.arrayBuffer());
  const ext = (file.name.split('.').pop() || 'jpg').toLowerCase().replace(/[^a-z0-9]/g, '').slice(0, 4) || 'jpg';
  const name = `${Date.now()}_${Math.random().toString(36).slice(2, 8)}.${ext}`;
  const dir = path.join(process.cwd(), 'public', 'uploads');
  await fs.mkdir(dir, { recursive: true });
  await fs.writeFile(path.join(dir, name), buf);
  return { url: `/uploads/${name}` };
}

async function getSessionSafe() {
  const { getSession } = await import('@/lib/auth');
  return getSession();
}

/* ============ 产品 ============ */
export async function saveProduct(formData: FormData) {
  const id = String(formData.get('id') || '');
  const seriesCode = String(formData.get('seriesCode') || '');
  const image = String(formData.get('image') || '') || null;
  const featured = formData.get('featured') === 'on';
  const zhName = String(formData.get('zh_name') || '').trim();
  const zhDesc = String(formData.get('zh_desc') || '').trim();
  const enName = String(formData.get('en_name') || '').trim();
  const enDesc = String(formData.get('en_desc') || '').trim();
  if (!zhName) return { error: '请填写产品中文名称' };
  const series = seriesCode ? await prisma.series.findUnique({ where: { code: seriesCode } }) : null;
  const i18n = JSON.stringify({
    zh: { name: zhName, description: zhDesc },
    en: { name: enName || zhName, description: enDesc },
  });
  if (id) {
    await prisma.product.update({ where: { id }, data: { seriesId: series?.id ?? null, image, featured, i18n } });
  } else {
    await prisma.product.create({ data: { slug: `p-${Date.now().toString(36)}`, seriesId: series?.id ?? null, image, featured, i18n } });
  }
  revalidatePath('/products', 'page'); revalidatePath('/', 'page'); revalidatePath('/zh'); revalidatePath('/en');
  redirect('/admin/products');
}

export async function deleteProduct(id: string) {
  await prisma.product.delete({ where: { id } });
  revalidatePath('/products', 'page'); revalidatePath('/', 'page');
}

/* ============ 系列 ============ */
export async function saveSeries(formData: FormData) {
  const id = String(formData.get('id') || '');
  const code = String(formData.get('code') || '').trim();
  const sortOrder = Number(formData.get('sortOrder') || 0);
  if (!code) throw new Error('请填写系列代号');
  const i18n = JSON.stringify({
    zh: { name: String(formData.get('zh_name') || code), subtitle: '', description: String(formData.get('zh_desc') || '') },
    en: { name: String(formData.get('en_name') || code), subtitle: '', description: String(formData.get('en_desc') || '') },
  });
  if (id) {
    await prisma.series.update({ where: { id }, data: { code, sortOrder, i18n } });
  } else {
    await prisma.series.create({ data: { code, sortOrder, i18n } });
  }
  revalidatePath('/products', 'page'); revalidatePath('/', 'page');
  redirect('/admin/series');
}

export async function deleteSeries(id: string) {
  await prisma.series.delete({ where: { id } });
  revalidatePath('/products', 'page'); revalidatePath('/', 'page');
}

/* ============ 新闻 ============ */
export async function saveNews(formData: FormData) {
  const id = String(formData.get('id') || '');
  const category = String(formData.get('category') || 'company');
  const coverImage = String(formData.get('coverImage') || '') || null;
  const dateStr = String(formData.get('publishedAt') || '');
  const publishedAt = dateStr ? new Date(dateStr) : new Date();
  const i18n = JSON.stringify({
    zh: { title: String(formData.get('zh_title') || ''), summary: String(formData.get('zh_summary') || ''), content: String(formData.get('zh_content') || '') },
    en: { title: String(formData.get('en_title') || ''), summary: String(formData.get('en_summary') || ''), content: String(formData.get('en_content') || '') },
  });
  if (id) {
    await prisma.news.update({ where: { id }, data: { category, coverImage, publishedAt, i18n } });
  } else {
    await prisma.news.create({ data: { slug: `n-${Date.now().toString(36)}`, category, coverImage, publishedAt, i18n } });
  }
  revalidatePath('/news', 'page'); revalidatePath('/', 'page');
  redirect('/admin/news');
}

export async function deleteNews(id: string) {
  await prisma.news.delete({ where: { id } });
  revalidatePath('/news', 'page'); revalidatePath('/', 'page');
}

/* ============ 样板工程 ============ */
export async function saveCase(formData: FormData) {
  const id = String(formData.get('id') || '');
  const coverImage = String(formData.get('coverImage') || '') || null;
  const i18n = JSON.stringify({
    zh: { title: String(formData.get('zh_title') || ''), location: String(formData.get('zh_location') || ''), content: String(formData.get('zh_content') || '') },
    en: { title: String(formData.get('en_title') || ''), location: String(formData.get('en_location') || ''), content: String(formData.get('en_content') || '') },
  });
  if (id) {
    await prisma.caseItem.update({ where: { id }, data: { coverImage, i18n } });
  } else {
    await prisma.caseItem.create({ data: { slug: `c-${Date.now().toString(36)}`, coverImage, i18n } });
  }
  revalidatePath('/cases', 'page'); revalidatePath('/', 'page');
  redirect('/admin/cases');
}

export async function deleteCase(id: string) {
  await prisma.caseItem.delete({ where: { id } });
  revalidatePath('/cases', 'page');
}

/* ============ 招聘 ============ */
export async function saveJob(formData: FormData) {
  const id = String(formData.get('id') || '');
  const department = String(formData.get('department') || '') || null;
  const location = String(formData.get('location') || '') || null;
  const i18n = JSON.stringify({
    zh: { title: String(formData.get('zh_title') || ''), requirements: String(formData.get('zh_requirements') || ''), description: String(formData.get('zh_description') || '') },
    en: { title: String(formData.get('en_title') || ''), requirements: String(formData.get('en_requirements') || ''), description: String(formData.get('en_description') || '') },
  });
  if (id) {
    await prisma.job.update({ where: { id }, data: { department, location, i18n } });
  } else {
    await prisma.job.create({ data: { slug: `j-${Date.now().toString(36)}`, department, location, i18n } });
  }
  revalidatePath('/careers', 'page');
  redirect('/admin/jobs');
}

export async function deleteJob(id: string) {
  await prisma.job.delete({ where: { id } });
  revalidatePath('/careers', 'page');
}

/* ============ 站点设置 (首页标语 / 联系方式) ============ */
export async function saveHero(formData: FormData) {
  const i18n = JSON.stringify({
    zh: { title: String(formData.get('zh_title') || ''), subtitle: String(formData.get('zh_subtitle') || ''), cta1: String(formData.get('zh_cta1') || ''), cta2: String(formData.get('zh_cta2') || '') },
    en: { title: String(formData.get('en_title') || ''), subtitle: String(formData.get('en_subtitle') || ''), cta1: String(formData.get('en_cta1') || ''), cta2: String(formData.get('en_cta2') || '') },
  });
  await prisma.setting.upsert({ where: { key: 'hero' }, update: { i18n }, create: { key: 'hero', i18n } });
  revalidatePath('/', 'page');
  revalidatePath('/admin/settings');
}

export async function saveContact(formData: FormData) {
  const i18n = JSON.stringify({
    zh: { phone: String(formData.get('zh_phone') || ''), phone2: String(formData.get('zh_phone2') || ''), email: String(formData.get('zh_email') || ''), address: String(formData.get('zh_address') || ''), icp: String(formData.get('zh_icp') || ''), company: String(formData.get('zh_company') || '') },
    en: { phone: String(formData.get('en_phone') || ''), phone2: String(formData.get('en_phone2') || ''), email: String(formData.get('en_email') || ''), address: String(formData.get('en_address') || ''), icp: String(formData.get('en_icp') || ''), company: String(formData.get('en_company') || '') },
  });
  await prisma.setting.upsert({ where: { key: 'contact' }, update: { i18n }, create: { key: 'contact', i18n } });
  revalidatePath('/', 'page'); revalidatePath('/contact', 'page');
  revalidatePath('/admin/settings');
}

/* ============ 留言 ============ */
export async function handleInquiry(id: string) {
  await prisma.inquiry.update({ where: { id }, data: { handled: true } });
  revalidatePath('/admin/inquiries');
}

export async function deleteInquiry(id: string) {
  await prisma.inquiry.delete({ where: { id } });
  revalidatePath('/admin/inquiries');
}
