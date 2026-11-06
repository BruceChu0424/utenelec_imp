import { readCmsResources } from '@/lib/cms-list-queries';
import { CmsContinuousTable } from '@/components/admin/CmsContinuousTable';
import Link from 'next/link';
import { prisma } from '@/lib/db';
import { requireCmsPermission } from '@/lib/auth';
import { pick } from '@/lib/content';
export default async function ResourcesAdmin() {
  await requireCmsPermission('website:media_manage');
  const resources = await readCmsResources(prisma);
  return <div><div className="flex flex-wrap items-center justify-between gap-4"><div><h1 className="text-2xl font-semibold">专业资料</h1></div><Link prefetch={false} className="btn-accent" href="/admin/resources/new">新增资料</Link></div>
    <div className="mt-7 overflow-x-auto rounded-lg border border-border bg-card"><CmsContinuousTable rowCount={resources.length} className="w-full text-left text-sm"><thead className="bg-muted/40"><tr>{['名称', '语言 / 版本', '文件', '状态', '操作'].map(x => <th className="p-4 font-medium" key={x}>{x}</th>)}</tr></thead><tbody>{resources.map(r => <tr className="border-t border-border" key={r.id}><td className="p-4">{pick<{ title?: string }>(r.i18n, 'zh')?.title || r.slug}</td><td className="p-4">{r.language} / {r.version}</td><td className="p-4 text-muted-foreground">{r.asset.originalName}</td><td className="p-4">{r.published ? '已发布' : '未发布'}</td><td className="p-4"><Link prefetch={false} className="text-accent underline underline-offset-4" href={`/admin/resources/${r.id}`}>编辑</Link></td></tr>)}</tbody></CmsContinuousTable>{!resources.length && <p className="p-10 text-center text-sm text-muted-foreground">尚无已建立的资料。上传文件并保存草稿后，可在发布中心审查。</p>}</div></div>;
}
