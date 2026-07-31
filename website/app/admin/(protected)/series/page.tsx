import Link from 'next/link';
import { prisma } from '@/lib/db';
import { tr } from '@/lib/content';
import { deleteSeries } from '@/app/admin/actions';
import { DeleteButton } from '@/components/admin/DeleteButton';
import { Plus } from 'lucide-react';

export default async function SeriesAdmin() {
  const series = await prisma.series.findMany({
    orderBy: { sortOrder: 'asc' },
    include: { _count: { select: { products: true } } },
  });
  return (
    <div>
      <div className="flex items-center justify-between">
        <h1 className="font-heading text-2xl font-bold">产品系列</h1>
        <Link href="/admin/series/edit" className="btn-accent btn-sm"><Plus className="h-4 w-4" />新增系列</Link>
      </div>
      <div className="mt-6 card-uten overflow-x-auto">
        <table className="w-full text-sm">
          <thead className="bg-muted text-left text-xs uppercase text-muted-foreground"><tr><th className="p-3">代号</th><th className="p-3">名称</th><th className="p-3">产品数</th><th className="p-3">排序</th><th className="p-3 text-right">操作</th></tr></thead>
          <tbody>
            {series.map((s) => {
              const t = tr<{ name: string }>(s.i18n, 'zh');
              return (
                <tr key={s.id} className="border-t border-border hover:bg-muted/30">
                  <td className="p-3 font-mono text-accent">{s.code}</td>
                  <td className="p-3 font-medium">{t.name}</td>
                  <td className="p-3 text-muted-foreground">{s._count.products}</td>
                  <td className="p-3 text-muted-foreground">{s.sortOrder}</td>
                  <td className="whitespace-nowrap p-3 text-right">
                    <Link href={`/admin/series/edit/${s.id}`} className="text-accent hover:underline">编辑</Link>
                    <span className="mx-2 text-border">|</span>
                    <DeleteButton action={() => deleteSeries(s.id)} confirmText="删除系列后其下产品将变为无系列，确认？" />
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
