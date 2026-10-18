import Link from 'next/link';
import { notFound } from 'next/navigation';
import { prisma } from '@/lib/db';
import { requireCmsPermission,hasCmsPermission } from '@/lib/auth';
import { cmsEditPermission,cmsEntityTypes,cmsSnapshotHash,readCmsSnapshot,type CmsSnapshot,type CmsEntityType } from '@/lib/cms-apply';
import { CmsRevisionPreview } from '@/components/admin/CmsRevisionPreview';
import { CmsRevisionActions } from '@/components/admin/CmsRevisionActions';
export default async function RevisionPage({params}:{params:Promise<{id:string}>}) {
  const session=await requireCmsPermission('website:view'),{id}=await params;
  const revision=await prisma.cmsRevision.findUnique({where:{id}});
  if(!revision||!cmsEntityTypes.includes(revision.entityType as CmsEntityType))notFound();
  const type=revision.entityType as CmsEntityType;
  const canPublish=hasCmsPermission(session,'website:publish'),canRollback=hasCmsPermission(session,'website:rollback');
  const canEdit=hasCmsPermission(session,cmsEditPermission(type));
  if(!canEdit&&!canPublish&&!canRollback)notFound();
  if(!revision.beforeState||!revision.afterState||!revision.baseHash||!revision.entityId)return <p>此历史记录缺少完整版本证据，请重新保存草稿。</p>;
  const before=JSON.parse(revision.beforeState) as CmsSnapshot,after=JSON.parse(revision.afterState) as CmsSnapshot;
  const baseline=revision.status==='PUBLISHED'?after:before;
  const current=await prisma.$transaction(tx=>readCmsSnapshot(tx,type,revision.entityId!,baseline.scope));
  const unchanged=cmsSnapshotHash(current)===(revision.status==='PUBLISHED'?cmsSnapshotHash(after):revision.baseHash);
  const owner=session.actorId??`local:${session.username}`;
  return <div className="pb-12"><Link href="/admin/releases" className="text-sm text-accent">返回发布记录</Link>
    <div className="mb-7 mt-5 border-b border-border pb-6"><h1 className="font-heading text-2xl font-semibold">{revision.title}</h1>
      <p className="mt-2 text-sm text-muted-foreground">{revision.status==='DRAFT'?'待审核草稿':revision.status==='PUBLISHED'?'已发布版本':'已放弃草稿'} · {revision.createdAt.toLocaleString('zh-CN',{timeZone:'Asia/Shanghai'})}</p>
      <p className="mt-2 break-all text-xs text-muted-foreground">版本 {revision.id}</p>
      <CmsRevisionActions id={id} unchanged={unchanged} publish={canPublish&&revision.status==='DRAFT'} rollback={canRollback&&revision.status==='PUBLISHED'} discard={canEdit&&revision.status==='DRAFT'&&revision.createdBy===owner} />
    </div>
    <CmsRevisionPreview before={before} after={after} />
    <details className="mt-8 border-t border-border pt-4"><summary className="cursor-pointer text-sm">查看版本与来源追踪信息</summary><dl className="mt-3 grid gap-2 break-all text-sm"><dt>内容稳定标识</dt><dd>{revision.entityId}</dd><dt>创建人标识</dt><dd>{revision.createdBy}</dd>{revision.publishedBy&&<><dt>发布人标识</dt><dd>{revision.publishedBy}</dd></>}<dt>版本基准摘要</dt><dd>{revision.baseHash}</dd></dl></details>
  </div>;
}
