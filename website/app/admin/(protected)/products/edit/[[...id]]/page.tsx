import { notFound } from 'next/navigation';
import { prisma } from '@/lib/db';
import type { Product, ProductVariant } from '@prisma/client';
import { getCmsEditState } from '@/lib/cms-revisions';
import { tr } from '@/lib/content';
import { ProductForm } from '@/components/admin/ProductForm';

export default async function ProductEditPage({ params }: { params: Promise<{ id?: string[] }> }) {
  const id = (await params).id?.[0];
  const [editing, series] = await Promise.all([
    id ? getCmsEditState('product', id) : Promise.resolve(null),
    prisma.series.findMany({ orderBy: { sortOrder: 'asc' } }),
  ]);
  const record = editing?.snapshot.record as unknown as Product | null;
  const product = record && editing ? {...record, series: series.find(s => s.id === record.seriesId) || null,
    variants: ([...editing.snapshot.variants] as unknown as ProductVariant[]).sort((a,b)=>a.sortOrder-b.sortOrder)} : null;
  if (id && !product) notFound();
  const seriesLite = series.map((s) => ({
    id: s.id,
    code: s.code,
    name: tr<{ name: string }>(s.i18n, 'zh').name,
    published: s.published,
    catalogRole: s.catalogRole,
  }));
  return <ProductForm baseHash={editing?.baseHash || ''} product={product} series={seriesLite} />;
}
