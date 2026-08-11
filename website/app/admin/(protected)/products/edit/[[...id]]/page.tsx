import { notFound } from 'next/navigation';
import { prisma } from '@/lib/db';
import { tr } from '@/lib/content';
import { ProductForm } from '@/components/admin/ProductForm';

export default async function ProductEditPage({ params }: { params: Promise<{ id?: string[] }> }) {
  const id = (await params).id?.[0];
  const [product, series] = await Promise.all([
    id ? prisma.product.findUnique({
      where: { id },
      include: { series: true, variants: { orderBy: { sortOrder: 'asc' } } },
    }) : Promise.resolve(null),
    prisma.series.findMany({ orderBy: { sortOrder: 'asc' } }),
  ]);
  if (id && !product) notFound();
  const seriesLite = series.map((s) => ({
    id: s.id,
    code: s.code,
    name: tr<{ name: string }>(s.i18n, 'zh').name,
    published: s.published,
    catalogRole: s.catalogRole,
  }));
  return <ProductForm product={product} series={seriesLite} />;
}
