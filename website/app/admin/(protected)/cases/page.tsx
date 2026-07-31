import Link from 'next/link';
import { prisma } from '@/lib/db';
import { tr } from '@/lib/content';
import { deleteCase } from '@/app/admin/actions';
import { DeleteButton } from '@/components/admin/DeleteButton';
import { Plus } from 'lucide-react';

export default async function CasesAdmin() {
  const cases = await prisma.caseItem.findMany({ orderBy: { sortOrder: 'asc' } });
  return (
    <div>
      <div className="flex items-center justify-between">
        <h1 className="font-heading text-2xl font-bold">样板工程</h1>
        <Link href="/admin/cases/edit" className="btn-accent btn-sm"><Plus className="h-4 w-4" />新增案例</Link>
      </div>
      <div className="mt-6 card-uten overflow-x-auto">
        <table className="w-full text-sm">
          <thead className="bg-muted text-left text-xs uppercase text-muted-foreground"><tr><th className="p-3">项目名称</th><th className="p-3">地点</th><th className="p-3 text-right">操作</th></tr></thead>
          <tbody>
            {cases.map((c) => {
              const t = tr<{ title: string; location?: string }>(c.i18n, 'zh');
              return (
                <tr key={c.id} className="border-t border-border hover:bg-muted/30">
                  <td className="p-3 font-medium">{t.title}</td>
                  <td className="p-3 text-muted-foreground">{t.location || '—'}</td>
                  <td className="whitespace-nowrap p-3 text-right">
                    <Link href={`/admin/cases/edit/${c.id}`} className="text-accent hover:underline">编辑</Link>
                    <span className="mx-2 text-border">|</span>
                    <DeleteButton action={() => deleteCase(c.id)} />
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
