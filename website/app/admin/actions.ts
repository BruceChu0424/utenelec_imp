'use server';
import { prisma } from '@/lib/db';
import { clearSession, clearSuccessfulLoginAttempts, consumeLoginAttempt, getLoginClientIdentifier,
  setSession, verifyLoginPassword, assertCmsSessionInTransaction } from '@/lib/auth';
import { createUploadDescriptor, storeUploadedWebp } from '@/lib/upload-storage';
import { cleanText, FormValidationError } from '@/lib/cms-inputs';
import { stageCmsRevision, formDataToCmsPayload, getCmsEditState, type CmsEntityType } from '@/lib/cms-revisions';
import { pickLocale } from '@/lib/content';
import { redirect } from 'next/navigation';
import sharp from 'sharp';

/* ============ 认证 ============ */
const LOGIN_FAILURE_MESSAGE = '用户名或密码错误，或尝试过于频繁，请稍后重试';
const MAX_PENDING_MEDIA = 64;
const MAX_PENDING_MEDIA_BYTES = 512 * 1024 * 1024;

export async function login(formData: FormData) {
  const username = cleanText(formData.get('username'), 128);
  const password = String(formData.get('password') || '').slice(0, 1024);
  const clientIdentifier = await getLoginClientIdentifier();
  if (!consumeLoginAttempt(clientIdentifier, username).allowed) {
    return { error: LOGIN_FAILURE_MESSAGE };
  }

  try {
    const user = await prisma.user.findUnique({ where: { username } });
    const passwordMatches = await verifyLoginPassword(password, user?.password);
    if (!user || !passwordMatches) return { error: LOGIN_FAILURE_MESSAGE };

    clearSuccessfulLoginAttempts(clientIdentifier, username);
    await setSession(user.username, user.password);
  } catch (error) {
    console.error('admin login failed', error);
    return { error: LOGIN_FAILURE_MESSAGE };
  }
  redirect('/admin');
}

export async function logout() {
  await clearSession();
  redirect('/admin/login');
}

/* ============ 图片上传 (生产 durable uploads / 本地 public/uploads) ============ */
export async function uploadImage(formData: FormData): Promise<{ url?: string; error?: string }> {
  const s = await getSessionSafe('website:media_manage');
  if (!s) return { error: '登录已失效或没有图片维护权限，请从 IMP 重新进入' };
  const file = formData.get('file');
  if (!(file instanceof File)) return { error: '未选择文件' };
  if (file.size > 8 * 1024 * 1024) return { error: '文件超过 8MB' };
  const buf = Buffer.from(await file.arrayBuffer());
  let processed: Buffer;
  try {
    const image = sharp(buf, { failOn: 'error', limitInputPixels: 40_000_000 });
    const metadata = await image.metadata();
    if (!metadata.width || !metadata.height || !metadata.format) throw new Error('missing metadata');
    if (!['jpeg', 'png', 'gif', 'webp'].includes(metadata.format)) throw new Error('unsupported format');
    if ((metadata.pages || 1) > 1) return { error: '暂不接受动画图片，请上传单帧 JPG、PNG 或 WebP' };
    if (metadata.width * metadata.height > 40_000_000) return { error: '图片总像素超过 4000 万' };
    processed = await image
      .rotate()
      .resize({ width: 3200, height: 3200, fit: 'inside', withoutEnlargement: true })
      .webp({ quality: 88, effort: 4 })
      .toBuffer();
  } catch {
    return { error: '图片无法完整解码，或不是有效的 JPG、PNG、GIF、WebP 文件' };
  }
  try {
    const descriptor = createUploadDescriptor(processed);
    await prisma.$transaction(async (tx) => {
      await assertCmsSessionInTransaction(tx, s, 'website:media_manage');
      const authorities = await tx.websiteStateAuthority.findMany({
        select: { id: true, authorityUuid: true },
        take: 2,
      });
      if (authorities.length !== 1 || authorities[0].id !== 'production' || authorities[0].authorityUuid === 'UNBOUND') {
        throw new Error('website database authority is not initialized');
      }
      const pending = await tx.websiteMediaObject.aggregate({
        where: { state: 'PENDING' },
        _count: { _all: true },
        _sum: { sizeBytes: true },
      });
      if (
        pending._count._all >= MAX_PENDING_MEDIA
        || (pending._sum.sizeBytes ?? 0) + descriptor.sizeBytes > MAX_PENDING_MEDIA_BYTES
      ) {
        throw new Error('pending media quota is exhausted; operator recovery is required');
      }
      await tx.websiteMediaObject.create({
        data: {
          publicPath: descriptor.publicPath,
          authorityId: 'production',
          sha256: descriptor.sha256,
          sizeBytes: descriptor.sizeBytes,
          state: 'PENDING',
        },
      });
    }, { isolationLevel: 'Serializable' });
    try {
      const url = await storeUploadedWebp(processed, {
        fileNameFactory: () => descriptor.fileName,
      });
      try {
        const committed = await prisma.$transaction(async tx => {
          await assertCmsSessionInTransaction(tx, s, 'website:media_manage');
          return tx.websiteMediaObject.updateMany({
          where: {
            publicPath: descriptor.publicPath,
            authorityId: 'production',
            sha256: descriptor.sha256,
            sizeBytes: descriptor.sizeBytes,
            state: 'PENDING',
          },
          data: { state: 'COMMITTED' },
          });
        }, { isolationLevel: 'Serializable' });
        if (committed.count !== 1) throw new Error('media reservation compare-and-set failed');
      } catch (error) {
        const observed = await prisma.websiteMediaObject.findUnique({
          where: { publicPath: descriptor.publicPath },
        }).catch(() => null);
        if (!observed
          || observed.authorityId !== 'production'
          || observed.sha256 !== descriptor.sha256
          || observed.sizeBytes !== descriptor.sizeBytes
          || observed.state !== 'COMMITTED') {
          throw error;
        }
      }
      return { url };
    } catch (error) {
      // Once the durable reservation exists, never guess which side of a
      // filesystem/SQLite boundary committed.  The fixed root recovery tool
      // reconciles PENDING evidence idempotently; application cleanup could
      // otherwise turn an ambiguous success into COMMITTED-without-file.
      throw error;
    }
  } catch (error) {
    console.error('image upload storage failed', error);
    return { error: '图片保存失败，请稍后重试或联系管理员检查媒体存储' };
  }
}

async function getSessionSafe(permission = 'website:content_edit') {
  const { getSession, hasCmsPermission } = await import('@/lib/auth');
  const session = await getSession();
  if (!session || !hasCmsPermission(session, permission)) return null;
  if (session.source === 'imp') return session;
  const user = await prisma.user.findUnique({ where: { username: session.username }, select: { id: true } });
  return user ? session : null;
}

async function requireAdmin(permission = 'website:content_edit') {
  if (!(await getSessionSafe(permission))) throw new Error('未授权的后台操作');
}


// Every public content save creates a durable, immutable review revision.
// Only the publisher in cms-revisions.ts is allowed to mutate public entities.
async function saveDraft(type: CmsEntityType, form: FormData, title: string) {
  let revisionId: string;
  try {
    const id = type === 'setting' ? cleanText(form.get('settingKey'), 80) : cleanText(form.get('id'), 100);
    const result = await stageCmsRevision({ entityType: type, entityId: id || undefined,
      operation: 'UPSERT', title: cleanText(form.get('zh_name') || form.get('zh_title'), 200) || title,
      payload: formDataToCmsPayload(form) });
    revisionId = result.revisionId;
  } catch (error) {
    return { error: error instanceof FormValidationError ? error.message : '未收到草稿保存确认，请先查看发布记录，再决定是否重试' };
  }
  redirect(`/admin/releases/${revisionId}`);
}
async function deleteDraft(type: CmsEntityType, id: string) {
  const current = await getCmsEditState(type, id);
  const expectedHash = current.baseHash;
  const content = pickLocale<{name?:string;title?:string}>(String(current.snapshot.record?.i18n||'{}'),'zh');
  const result = await stageCmsRevision({ entityType: type, entityId: id, operation: 'DELETE',
    title: `删除：${content?.name||content?.title||String(current.snapshot.record?.code||id)}`, payload: {}, expectedHash });
  redirect(`/admin/releases/${result.revisionId}`);
}
export async function saveProduct(formData: FormData) { return saveDraft('product', formData, '产品'); }
export async function saveSeries(formData: FormData) { return saveDraft('series', formData, '产品系列'); }
export async function saveScenePreset(formData: FormData) { return saveDraft('scene', formData, '场景试装'); }
export async function saveNews(formData: FormData) { return saveDraft('news', formData, '新闻'); }
export async function saveCase(formData: FormData) { return saveDraft('case', formData, '工程案例'); }
export async function saveJob(formData: FormData) { return saveDraft('job', formData, '招聘岗位'); }
export async function saveSiteSetting(formData: FormData) { return saveDraft('setting', formData, '网站栏目'); }
export async function saveHero(formData: FormData) { formData.set('settingKey', 'hero'); return saveSiteSetting(formData); }
export async function saveContact(formData: FormData) { formData.set('settingKey', 'contact'); return saveSiteSetting(formData); }
export async function deleteProduct(id: string) { return deleteDraft('product', id); }
export async function deleteSeries(id: string) { return deleteDraft('series', id); }
export async function deleteScenePreset(id: string) { return deleteDraft('scene', id); }
export async function deleteNews(id: string) { return deleteDraft('news', id); }
export async function deleteCase(id: string) { return deleteDraft('case', id); }
export async function deleteJob(id: string) { return deleteDraft('job', id); }

/* ============ 留言 ============ */
export async function handleInquiry(id: string) {
  await requireAdmin('webinquiry:view');
  void id;
  throw new Error('询盘由 IMP 销售工作台统一办理，官网保留受理与投递记录');
}

export async function deleteInquiry(id: string) {
  await requireAdmin('webinquiry:view');
  void id;
  throw new Error('官网询盘不可从内容编辑器删除，请按公司数据保留规则处理');
}
