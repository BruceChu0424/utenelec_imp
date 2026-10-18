import { notFound } from 'next/navigation';
import { prisma } from '@/lib/db';
import type { Series, SeriesMedia } from '@prisma/client';
import { getCmsEditState } from '@/lib/cms-revisions';
import { pickLocale } from '@/lib/content';
import { SeriesForm } from '@/components/admin/SeriesForm';

type SeriesNode = {
  id: string;
  parentId: string | null;
};

function findDescendantIds(items: SeriesNode[], rootId: string): Set<string> {
  const children = new Map<string, string[]>();
  for (const item of items) {
    if (!item.parentId) continue;
    children.set(item.parentId, [...(children.get(item.parentId) || []), item.id]);
  }

  const descendants = new Set<string>();
  const pending = [...(children.get(rootId) || [])];
  while (pending.length) {
    const current = pending.pop();
    if (!current || descendants.has(current)) continue;
    descendants.add(current);
    pending.push(...(children.get(current) || []));
  }
  return descendants;
}

export default async function SeriesEditPage({ params }: { params: Promise<{ id?: string[] }> }) {
  const id = (await params).id?.[0];
  const allSeries = await prisma.series.findMany({
    orderBy: [{ sortOrder: 'asc' }, { code: 'asc' }],
    include: { media: { orderBy: [{ sortOrder: 'asc' }, { createdAt: 'asc' }] } },
  });
  const editing = id ? await getCmsEditState('series', id) : null;
  const series = editing?.snapshot.record ? { ...(editing.snapshot.record as unknown as Series), media: editing.snapshot.media as unknown as SeriesMedia[] } : null;
  if (id && !series) notFound();

  const unavailableParentIds = series
    ? new Set([series.id, ...findDescendantIds(allSeries, series.id)])
    : new Set<string>();
  const parentOptions = allSeries
    .filter((item) => !unavailableParentIds.has(item.id))
    .map((item) => ({
      id: item.id,
      code: item.code,
      name: pickLocale<{ name?: string }>(item.i18n, 'zh')?.name?.trim() || item.code,
    }));
  const editableSeries = series ? {
    id: series.id,
    code: series.code,
    publicSlug: series.publicSlug,
    catalogRole: series.catalogRole,
    rowVersion: series.rowVersion,
    i18n: series.i18n,
    coverImage: series.coverImage,
    sortOrder: series.sortOrder,
    published: series.published,
    parentId: series.parentId,
    media: series.media,
  } : null;

  return <SeriesForm baseHash={editing?.baseHash || ''} series={editableSeries} parentOptions={parentOptions} />;
}
