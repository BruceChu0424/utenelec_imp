'use server';
import { prisma } from '@/lib/db';
import { requireCmsPermission, assertCmsSessionInTransaction } from '@/lib/auth';
import { storeDocument, discardUncommittedDocument, MAX_DOCUMENT_BYTES } from '@/lib/document-storage';
import { stageCmsRevision, formDataToCmsPayload } from '@/lib/cms-revisions';
import { redirect } from 'next/navigation';

export async function uploadDocument(form: FormData): Promise<{ id?: string; name?: string; error?: string }> {
  try {
    const session = await requireCmsPermission('website:media_manage');
    const file = form.get('file');
    if (!(file instanceof File) || !file.size || file.size > MAX_DOCUMENT_BYTES) return { error: '请上传不超过 20 MB 的 PDF 文件' };
    const stored = await storeDocument(new Uint8Array(await file.arrayBuffer()));
    try {
      const name = file.name.replace(/[\u0000-\u001f/\\]/g, '_').slice(0, 180) || 'product-document.pdf';
      const asset = await prisma.$transaction(async tx => {
        await assertCmsSessionInTransaction(tx, session, 'website:media_manage');
        const asset = await tx.websiteDocumentAsset.create({ data: { ...stored, originalName: name, createdBy: session.actorId || session.username } });
        await tx.cmsAuditEvent.create({ data: { actorId: session.actorId || session.username, action: 'document_upload', entityType: 'document_asset', entityId: asset.id, summary: '上传待发布 PDF 资料' } });
        return asset;
      }, { isolationLevel: 'Serializable' });
      return { id: asset.id, name: asset.originalName };
    } catch (error) { await discardUncommittedDocument(stored.storageKey); throw error; }
  } catch (error) { return { error: error instanceof Error ? error.message : '资料上传失败，请重试' }; }
}

export async function saveResource(form: FormData): Promise<{ error?: string }> {
  let revisionId: string;
  try {
    const payload = formDataToCmsPayload(form);
    const result = await stageCmsRevision({ entityType: 'resource', entityId: String(form.get('id') || '') || undefined,
      operation: 'UPSERT', title: String(form.get('zh_title') || '产品资料').slice(0, 160), payload,
      expectedVersion: form.get('rowVersion') ? Number(form.get('rowVersion')) : undefined,
      expectedHash: String(form.get('expectedHash') || '') || undefined });
    revisionId = result.revisionId;
  } catch (error) { return { error: error instanceof Error ? error.message : '资料草稿保存失败，请刷新后重试' }; }
  redirect(`/admin/releases/${revisionId}`);
}
