import Link from 'next/link';
import { prisma } from '@/lib/db';
import { tr } from '@/lib/content';
import { deleteJob } from '@/app/admin/actions';
import { DeleteButton } from '@/components/admin/DeleteButton';
import { Plus } from 'lucide-react';

export default async function JobsAdmin() {
  const jobs = await prisma.job.findMany({ orderBy: { sortOrder: 'asc' } });
  return (
    <div>
      <div className="flex items-center justify-between">
        <h1 className="font-heading text-2xl font-bold">人才招聘</h1>
        <Link href="/admin/jobs/edit" className="btn-accent btn-sm"><Plus className="h-4 w-4" />新增岗位</Link>
      </div>
      <div className="mt-6 card-uten overflow-x-auto">
        <table className="w-full text-sm">
          <thead className="bg-muted text-left text-xs uppercase text-muted-foreground"><tr><th className="p-3">岗位</th><th className="p-3">部门</th><th className="p-3">地点</th><th className="p-3 text-right">操作</th></tr></thead>
          <tbody>
            {jobs.map((j) => {
              const t = tr<{ title: string }>(j.i18n, 'zh');
              return (
                <tr key={j.id} className="border-t border-border hover:bg-muted/30">
                  <td className="p-3 font-medium">{t.title}</td>
                  <td className="p-3 text-muted-foreground">{j.department || '—'}</td>
                  <td className="p-3 text-muted-foreground">{j.location || '—'}</td>
                  <td className="whitespace-nowrap p-3 text-right">
                    <Link href={`/admin/jobs/edit/${j.id}`} className="text-accent hover:underline">编辑</Link>
                    <span className="mx-2 text-border">|</span>
                    <DeleteButton action={deleteJob.bind(null, j.id)} />
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}
