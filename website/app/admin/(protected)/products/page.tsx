/* eslint-disable @next/next/no-img-element */
import Link from 'next/link';
import type { Prisma } from '@prisma/client';
import { Plus, Search } from 'lucide-react';
import { prisma } from '@/lib/db';
import { tr } from '@/lib/content';
import { deleteProduct } from '@/app/admin/actions';
import { DeleteButton } from '@/components/admin/DeleteButton';
import { PRODUCT_CLASSIFICATION_STATUSES, PRODUCT_FUNCTION_TYPES } from '@/lib/product-taxonomy';

const PAGE_SIZE = 40;

type ProductSearchParams = {
  q?: string | string[];
  series?: string | string[];
  functionType?: string | string[];
  review?: string | string[];
  page?: string | string[];
  error?: string | string[];
};

const first = (value: string | string[] | undefined) => (Array.isArray(value) ? value[0] : value) || '';

const errorMessages: Record<string, string> = {
  'unpublish-before-delete': '已发布产品禁止硬删除。请先编辑产品并取消发布，再执行删除。',
};

export default async function ProductsAdmin({
  searchParams,
}: {
  searchParams: Promise<ProductSearchParams>;
}) {
  const params = await searchParams;
  const q = first(params.q).trim().slice(0, 120);
  const seriesId = first(params.series).slice(0, 80);
  const functionType = first(params.functionType).slice(0, 60);
  const review = first(params.review).slice(0, 40);
  const requestedPage = Math.max(1, Number.parseInt(first(params.page), 10) || 1);
  const error = errorMessages[first(params.error)] || '';

  const where: Prisma.ProductWhereInput = {
    ...(seriesId ? { seriesId } : {}),
    ...(functionType ? { functionType } : {}),
    ...(review ? { classificationStatus: review } : {}),
    ...(q ? {
      OR: [
        { slug: { contains: q } },
        { model: { contains: q } },
        { category: { contains: q } },
        { i18n: { contains: q } },
        { variants: { some: { sku: { contains: q } } } },
      ],
    } : {}),
  };
  const [total, seriesOptions] = await Promise.all([
    prisma.product.count({ where }),
    prisma.series.findMany({ orderBy: [{ sortOrder: 'asc' }, { code: 'asc' }], select: { id: true, code: true, i18n: true } }),
  ]);
  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const page = Math.min(requestedPage, totalPages);
  const products = await prisma.product.findMany({
    where,
    orderBy: [{ featured: 'desc' }, { sortOrder: 'asc' }, { id: 'asc' }],
    skip: (page - 1) * PAGE_SIZE,
    take: PAGE_SIZE,
    include: {
      series: true,
      _count: { select: { variants: true } },
      variants: {
        where: { image: { not: null } },
        orderBy: [{ isDefault: 'desc' }, { sortOrder: 'asc' }],
        take: 1,
        select: { image: true },
      },
    },
  });

  const hrefForPage = (target: number) => {
    const query = new URLSearchParams();
    if (q) query.set('q', q);
    if (seriesId) query.set('series', seriesId);
    if (functionType) query.set('functionType', functionType);
    if (review) query.set('review', review);
    query.set('page', String(target));
    return `/admin/products?${query.toString()}`;
  };

  return (
    <div>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="font-heading text-2xl font-bold">产品管理</h1>
          <p className="text-sm text-muted-foreground">筛选结果 {total} 个；每页最多 {PAGE_SIZE} 个产品</p>
        </div>
        <Link href="/admin/products/edit" className="btn-accent btn-sm min-h-11"><Plus className="h-4 w-4" />新增产品</Link>
      </div>

      {error && <div role="alert" className="mt-4 rounded-lg bg-destructive/10 px-4 py-3 text-sm text-destructive">{error}</div>}

      <form method="get" className="mt-5 card-uten grid gap-3 p-4 md:grid-cols-2 xl:grid-cols-[minmax(220px,1fr)_repeat(3,minmax(150px,.55fr))_auto]" aria-label="产品筛选">
        <div>
          <label htmlFor="product-search" className="label-uten">搜索</label>
          <div className="relative">
            <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
            <input id="product-search" name="q" defaultValue={q} maxLength={120} className="input-uten pl-9" placeholder="名称、型号、SKU 或内部分类" />
          </div>
        </div>
        <div>
          <label htmlFor="series-filter" className="label-uten">系列</label>
          <select id="series-filter" name="series" defaultValue={seriesId} className="input-uten">
            <option value="">全部系列</option>
            {seriesOptions.map((item) => <option key={item.id} value={item.id}>{tr<{ name: string }>(item.i18n, 'zh').name} · {item.code}</option>)}
          </select>
        </div>
        <div>
          <label htmlFor="function-filter" className="label-uten">功能类型</label>
          <select id="function-filter" name="functionType" defaultValue={functionType} className="input-uten">
            <option value="">全部功能</option>
            {PRODUCT_FUNCTION_TYPES.map((value) => <option key={value} value={value}>{value}</option>)}
          </select>
        </div>
        <div>
          <label htmlFor="review-filter" className="label-uten">审核状态</label>
          <select id="review-filter" name="review" defaultValue={review} className="input-uten">
            <option value="">全部状态</option>
            {PRODUCT_CLASSIFICATION_STATUSES.map((value) => <option key={value} value={value}>{value}</option>)}
          </select>
        </div>
        <div className="flex items-end gap-2">
          <button type="submit" className="btn-accent min-h-11">筛选</button>
          <Link href="/admin/products" className="btn-outline min-h-11">重置</Link>
        </div>
      </form>

      <div className="mt-5 card-uten overflow-x-auto">
        <table className="w-full min-w-[1040px] text-sm">
          <thead className="bg-muted text-left text-xs uppercase text-muted-foreground">
            <tr><th className="p-3">图片</th><th className="p-3">名称 / 型号</th><th className="p-3">系列</th><th className="p-3">功能 / 审核</th><th className="p-3">款式</th><th className="p-3">状态</th><th className="p-3 text-right">操作</th></tr>
          </thead>
          <tbody>
            {products.map((product) => {
              const localized = tr<{ name: string }>(product.i18n, 'zh');
              const image = product.image || product.variants[0]?.image;
              return (
                <tr key={product.id} className="border-t border-border hover:bg-muted/30">
                  <td className="p-3">{image ? <img src={image} alt="" className="h-11 w-11 rounded-lg object-cover" /> : <div className="grid h-11 w-11 place-items-center rounded-lg bg-muted text-xs text-muted-foreground">无图</div>}</td>
                  <td className="p-3"><p className="font-medium">{localized.name}</p><p className="mt-0.5 font-mono text-xs text-muted-foreground">{product.model || '未填型号'}</p></td>
                  <td className="p-3 text-muted-foreground">{product.series ? tr<{ name: string }>(product.series.i18n, 'zh').name : '无系列'}</td>
                  <td className="p-3"><p>{product.functionType || '未分类'}</p><p className="mt-1 text-xs text-muted-foreground">{product.classificationStatus}</p></td>
                  <td className="p-3 tabular-nums">{product._count.variants}</td>
                  <td className="p-3 text-xs"><p className={product.published ? 'text-accent' : 'text-muted-foreground'}>{product.published ? '已发布' : '未发布'}</p>{product.sceneEnabled && <p className="mt-1 text-muted-foreground">可试装</p>}</td>
                  <td className="whitespace-nowrap p-3 text-right"><Link href={`/admin/products/edit/${product.id}`} className="text-accent hover:underline">编辑</Link><span className="mx-2 text-border">|</span><DeleteButton action={deleteProduct.bind(null, product.id)} /></td>
                </tr>
              );
            })}
            {!products.length && <tr><td colSpan={7} className="p-10 text-center text-muted-foreground">没有符合条件的产品，请调整筛选条件。</td></tr>}
          </tbody>
        </table>
      </div>

      <nav className="mt-5 flex items-center justify-between gap-3" aria-label="产品分页">
        <p className="text-sm text-muted-foreground">第 {page} / {totalPages} 页</p>
        <div className="flex gap-2">
          {page > 1 ? <Link href={hrefForPage(page - 1)} className="btn-outline min-h-11">上一页</Link> : <span className="btn-outline min-h-11 cursor-not-allowed opacity-40">上一页</span>}
          {page < totalPages ? <Link href={hrefForPage(page + 1)} className="btn-outline min-h-11">下一页</Link> : <span className="btn-outline min-h-11 cursor-not-allowed opacity-40">下一页</span>}
        </div>
      </nav>
    </div>
  );
}
