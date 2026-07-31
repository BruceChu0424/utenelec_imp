/* eslint-disable @next/next/no-img-element */
import Link from 'next/link';
import { prisma } from '@/lib/db';
import { tr } from '@/lib/content';
import { deleteProduct } from '@/app/admin/actions';
import { DeleteButton } from '@/components/admin/DeleteButton';
import { Plus } from 'lucide-react';

export default async function ProductsAdmin() {
  const products = await prisma.product.findMany({
    orderBy: [{ featured: 'desc' }, { sortOrder: 'asc' }],
    include: { series: true },
  });
  return (
    <div>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="font-heading text-2xl font-bold">产品管理</h1>
          <p className="text-sm text-muted-foreground">共 {products.length} 个产品</p>
        </div>
        <Link href="/admin/products/edit" className="btn-accent btn-sm"><Plus className="h-4 w-4" />新增产品</Link>
      </div>
      <div className="mt-6 card-uten overflow-x-auto">
        <table className="w-full text-sm">
          <thead className="bg-muted text-left text-xs uppercase text-muted-foreground">
            <tr><th className="p-3">图片</th><th className="p-3">名称</th><th className="p-3">系列</th><th className="p-3">推荐</th><th className="p-3 text-right">操作</th></tr>
          </thead>
          <tbody>
            {products.map((p) => {
              const t = tr<{ name: string }>(p.i18n, 'zh');
              return (
                <tr key={p.id} className="border-t border-border hover:bg-muted/30">
                  <td className="p-3">{p.image ? <img src={p.image} alt="" className="h-11 w-11 rounded-lg object-cover" /> : <div className="grid h-11 w-11 place-items-center rounded-lg bg-muted text-xs text-muted-foreground">无图</div>}</td>
                  <td className="p-3 font-medium">{t.name}</td>
                  <td className="p-3 text-muted-foreground">{p.series ? tr<{ name: string }>(p.series.i18n, 'zh').name : <span className="text-muted-foreground/50">—</span>}</td>
                  <td className="p-3">{p.featured ? <span className="text-accent">★ 推荐</span> : '—'}</td>
                  <td className="whitespace-nowrap p-3 text-right">
                    <Link href={`/admin/products/edit/${p.id}`} className="text-accent hover:underline">编辑</Link>
                    <span className="mx-2 text-border">|</span>
                    <DeleteButton action={() => deleteProduct(p.id)} />
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
