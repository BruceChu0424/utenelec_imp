import { readCmsReleases } from '@/lib/cms-list-queries';
import { AdminHint } from '@/components/admin/AdminHint';
import { CmsContinuousTable } from '@/components/admin/CmsContinuousTable';
import Link from 'next/link';
import { prisma } from '@/lib/db';
import { requireCmsPermission,hasCmsPermission } from '@/lib/auth';
import { cmsEditPermission,cmsEntityTypes } from '@/lib/cms-apply';
const types:Record<string,string>={product:'产品',series:'系列',scene:'场景',news:'新闻',case:'工程案例',job:'岗位',setting:'网站栏目',resource:'技术资料'};
const statuses:Record<string,string>={DRAFT:'待审核',PUBLISHED:'已发布',DISCARDED:'已放弃'};
export default async function ReleasesPage({searchParams}:{searchParams:Promise<Record<string,string|undefined>>}) {
  const session=await requireCmsPermission('website:view'),query=await searchParams;
  const allowed=cmsEntityTypes.filter(type=>hasCmsPermission(session,cmsEditPermission(type))||hasCmsPermission(session,'website:publish')||hasCmsPermission(session,'website:rollback'));
  const status=['DRAFT','PUBLISHED','DISCARDED'].includes(query.status||'')?query.status:undefined;
  const revisions=await readCmsReleases(prisma,allowed,status),total=revisions.length;
  return <div className="pb-10"><div className="flex items-center gap-2"><h1 className="font-heading text-3xl font-semibold">发布记录</h1><AdminHint text="编辑先保存草稿。逐个预览确定的版本，再发布到官网；恢复会生成新的记录并保留原始来源。" /></div>
    <nav aria-label="版本状态" className="my-6 flex flex-wrap gap-3">{[['','全部'],['DRAFT','待审核'],['PUBLISHED','已发布'],['DISCARDED','已放弃']].map(([value,label])=><Link prefetch={false} key={value} href={`/admin/releases${value?`?status=${value}`:''}`} className={`btn-outline btn-sm ${status===value||!status&&!value?'border-accent text-accent':''}`}>{label}</Link>)}</nav>
    {!allowed.length?<p>当前账号没有内容维护或发布权限，请从 IMP 检查授权。</p>:revisions.length?<div className="overflow-x-auto"><CmsContinuousTable rowCount={revisions.length} className="w-full min-w-[650px] text-left text-sm"><thead><tr className="border-b border-border"><th className="p-3">内容</th><th className="p-3">类型</th><th className="p-3">状态</th><th className="p-3">保存时间</th><th className="p-3">操作</th></tr></thead>
      <tbody>{revisions.map(r=><tr key={r.id} className="border-b border-border"><td className="p-3 font-medium">{r.title}{r.operation==='DELETE'&&<span className="ml-2 text-destructive">删除申请</span>}</td><td className="p-3">{types[r.entityType]||r.entityType}</td><td className="p-3">{statuses[r.status]||'处理中'}</td><td className="p-3">{r.createdAt.toLocaleString('zh-CN',{timeZone:'Asia/Shanghai'})}</td><td className="p-3"><Link prefetch={false} className="text-accent underline-offset-4 hover:underline" href={`/admin/releases/${r.id}`}>查看版本</Link></td></tr>)}</tbody></CmsContinuousTable></div>:<p className="rounded-xl border border-dashed border-border p-8 text-muted-foreground">尚无版本记录。保存首页、产品或其它内容后，草稿会出现在这里。</p>}
    <div className="mt-5 text-sm text-muted-foreground">共 {total} 个版本</div>
  </div>;
}
