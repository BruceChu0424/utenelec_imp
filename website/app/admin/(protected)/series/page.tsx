import Link from 'next/link';
import { prisma } from '@/lib/db';
import { tr } from '@/lib/content';
import { deleteSeries } from '@/app/admin/actions';
import { DeleteButton } from '@/components/admin/DeleteButton';
import { Plus } from 'lucide-react';

const errorMessages: Record<string, string> = {
  'unpublish-before-delete': '已发布系列禁止硬删除，请先编辑系列并取消发布。',
  'series-not-empty': '该系列仍有下级系列或产品。请先迁移这些记录，避免产品静默失去系列。',
  'series-state-changed': '系列状态已变化，请刷新后重试。',
};

export default async function SeriesAdmin({ searchParams }: { searchParams: Promise<{ error?: string | string[] }> }) {
  const rawError = (await searchParams).error;
  const error = errorMessages[Array.isArray(rawError) ? rawError[0] : rawError || ''] || '';
  const series = await prisma.series.findMany({
    orderBy: { sortOrder: 'asc' },
    include: { _count: { select: { products: true, media: true } } },
  });
  return (
    <div>
      <div className="flex items-center justify-between">
        <h1 className="font-heading text-2xl font-bold">产品系列</h1>
        <Link href="/admin/series/edit" className="btn-accent btn-sm"><Plus className="h-4 w-4" />新增系列</Link>
      </div>
      {error && <div role="alert" className="mt-4 rounded-lg bg-destructive/10 px-4 py-3 text-sm text-destructive">{error}</div>}
      <div className="mt-6 card-uten overflow-x-auto">
        <table className="w-full min-w-[920px] text-sm">
          <thead className="bg-muted text-left text-xs uppercase text-muted-foreground"><tr><th className="p-3">代号 / 聚合网址</th><th className="p-3">名称</th><th className="p-3">目录角色</th><th className="p-3">产品 / 素材</th><th className="p-3">状态</th><th className="p-3 text-right">操作</th></tr></thead>
          <tbody>
            {series.map((s) => {
              const t = tr<{ name: string }>(s.i18n, 'zh');
              return (
                <tr key={s.id} className="border-t border-border hover:bg-muted/30">
                  <td className="p-3"><p className="font-mono text-accent">{s.code}</p><p className="mt-1 font-mono text-xs text-muted-foreground">{s.publicSlug || '未设聚合网址'}</p></td>
                  <td className="p-3 font-medium">{t.name}</td>
                  <td className="p-3 text-muted-foreground">{s.catalogRole}</td>
                  <td className="p-3 text-muted-foreground">{s._count.products} / {s._count.media}</td>
                  <td className="p-3"><p className={s.published ? 'text-accent' : 'text-muted-foreground'}>{s.published ? '已发布' : '未发布'}</p><p className="mt-1 text-xs text-muted-foreground">v{s.rowVersion}</p></td>
                  <td className="whitespace-nowrap p-3 text-right">
                    <Link href={`/admin/series/edit/${s.id}`} className="text-accent hover:underline">编辑</Link>
                    <span className="mx-2 text-border">|</span>
                    <DeleteButton action={deleteSeries.bind(null, s.id)} confirmText="仅允许删除已下架且没有产品/下级的系列，确认继续？" />
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
