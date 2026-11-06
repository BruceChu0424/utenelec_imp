import { readCmsCases } from '@/lib/cms-list-queries';
import { requireCmsPermission } from '@/lib/auth';
import { CmsContinuousTable } from '@/components/admin/CmsContinuousTable';
import Link from 'next/link';
import { prisma } from '@/lib/db';
import { tr } from '@/lib/content';
import { deleteCase } from '@/app/admin/actions';
import { CmsDeleteButton } from '@/components/admin/CmsDeleteButton';
import { Plus } from 'lucide-react';

export default async function CasesAdmin() {
  await requireCmsPermission('website:view');
  const cases = await readCmsCases(prisma);
  return (
    <div>
      <div className="flex items-center justify-between">
        <h1 className="font-heading text-2xl font-bold">案例与足迹</h1>
        <Link prefetch={false} href="/admin/cases/edit" className="btn-accent btn-sm"><Plus className="h-4 w-4" />新增案例</Link>
      </div>
      <div className="mt-6 card-uten overflow-x-auto">
        <CmsContinuousTable rowCount={cases.length} className="w-full text-sm">
          <thead className="bg-muted text-left text-xs uppercase text-muted-foreground"><tr><th className="p-3">项目名称</th><th className="p-3">地点</th><th className="p-3 text-right">操作</th></tr></thead>
          <tbody>
            {cases.map((c) => {
              const t = tr<{ title: string; location?: string }>(c.i18n, 'zh');
              return (
                <tr key={c.id} className="border-t border-border hover:bg-muted/30">
                  <td className="p-3 font-medium">{t.title}</td>
                  <td className="p-3 text-muted-foreground">{t.location || '—'}</td>
                  <td className="whitespace-nowrap p-3 text-right">
                    <Link prefetch={false} href={`/admin/cases/edit/${c.id}`} className="text-accent hover:underline">编辑</Link>
                    <span className="mx-2 text-border">|</span>
                    <CmsDeleteButton draft targetId={c.id} action={deleteCase} />
                  </td>
                </tr>
              );
            })}
          </tbody>
        </CmsContinuousTable>
      </div>
    </div>
  );
}
