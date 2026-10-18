import { notFound } from 'next/navigation';
import { prisma } from '@/lib/db';
import { requireCmsPermission } from '@/lib/auth';
import { getCmsBaseHash } from '@/lib/cms-revisions';
import { ResourceForm } from '@/components/admin/ResourceForm';
import { pick } from '@/lib/content';
export default async function ResourceEditor({ params }: { params: Promise<{ id: string }> }) {
  await requireCmsPermission('website:media_manage'); const { id } = await params;
  const initial = id === 'new' ? null : await prisma.resourceDocument.findUnique({ where: { id }, include: { asset: true } });
  if (id !== 'new' && !initial) notFound();
  const [series, products] = await Promise.all([
    prisma.series.findMany({ orderBy: [{ sortOrder: 'asc' }, { code: 'asc' }], select: { id: true, code: true, i18n: true } }),
    prisma.product.findMany({ orderBy: [{ sortOrder: 'asc' }, { id: 'asc' }], select: { id: true, i18n: true, model: true, series: { select: { code: true } } } }),
  ]);
  return <div><h1 className="text-2xl font-semibold">{initial ? '编辑资料' : '新增资料'}</h1><ResourceForm initial={initial || undefined} expectedHash={initial ? await getCmsBaseHash('resource', initial.id) : ''}
    series={series.map(s => ({ id: s.id, name: pick<{ name?: string }>(s.i18n, 'zh')?.name || s.code }))}
    products={products.map(p => ({ id: p.id, name: `${p.series?.code || ''} · ${pick<{ name?: string }>(p.i18n, 'zh')?.name || p.model || p.id}` }))} /></div>;
}
