import Link from 'next/link';
import { prisma } from '@/lib/db';
import { requireCmsPermission } from '@/lib/auth';
import { ImageUpload } from '@/components/admin/ImageUpload';
import { MediaPath } from '@/components/admin/MediaPath';
export default async function MediaLibrary({ searchParams }: { searchParams: Promise<{ page?: string; source?: string }> }) {
  await requireCmsPermission('website:media_manage'); const query = await searchParams;
  const page = Math.min(100000, Math.max(1, Math.trunc(Number(query.page) || 1))), archive = query.source === 'archive';
  const size = 36;
  const [total, images] = archive ? await Promise.all([
    prisma.legacyMediaAsset.count({ where: { publicPath: { not: null } } }),
    prisma.legacyMediaAsset.findMany({ where: { publicPath: { not: null } }, orderBy: { id: 'asc' }, skip: (page - 1) * size, take: size,
      select: { id: true, publicPath: true, bytes: true } }).then(rows => rows.map(r => ({ id: r.id, publicPath: r.publicPath!, sizeBytes: r.bytes }))),
  ]) : await Promise.all([
    prisma.websiteMediaObject.count({ where: { state: 'COMMITTED' } }),
    prisma.websiteMediaObject.findMany({ where: { state: 'COMMITTED' }, orderBy: [{ createdAt: 'desc' }, { publicPath: 'asc' }], skip: (page - 1) * size, take: size,
      select: { publicPath: true, sizeBytes: true } }).then(rows => rows.map(r => ({ ...r, id: r.publicPath }))),
  ]);
  return <div className="max-w-7xl"><h1 className="text-2xl font-semibold">图片素材</h1><p className="mt-3 text-sm leading-7 text-muted-foreground">上传图片后，将图片路径用于栏目、产品或场景草稿。已引用素材保留，避免损坏线上页面和历史发布版本。</p>
    <section className="mt-6 max-w-3xl rounded-lg border border-border bg-card p-5"><h2 className="mb-4 font-semibold">上传新图片</h2><ImageUpload name="library-image" /><Link href="/admin/media" className="mt-4 inline-block text-sm text-accent underline underline-offset-4">刷新已上传素材</Link></section>
    <nav className="my-7 flex gap-6 border-b border-border pb-3 text-sm" aria-label="素材来源"><Link href="/admin/media" className={!archive ? 'font-semibold text-accent' : ''}>上传素材</Link><Link href="/admin/media?source=archive" className={archive ? 'font-semibold text-accent' : ''}>旧站档案</Link><span className="ml-auto text-muted-foreground">{total} 件</span></nav>
    <div className="grid gap-5 sm:grid-cols-2 xl:grid-cols-3">{images.map(image => <article className="rounded-lg border border-border bg-card p-4" key={image.id}>
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img src={image.publicPath} alt="素材预览" loading="lazy" className="mb-4 h-44 w-full bg-muted/30 object-contain" />
      <MediaPath path={image.publicPath} /><p className="mt-2 text-xs text-muted-foreground">{Math.max(1, Math.round(image.sizeBytes / 1024))} KB · {archive ? '保留原始来源' : '上传记录已核验'}</p>
    </article>)}</div>{!images.length && <p className="rounded-lg border border-border p-10 text-center text-sm text-muted-foreground">暂无此来源素材。可以上传新图片，或切换到旧站档案。</p>}
    <div className="mt-7 flex gap-5 text-sm">{page > 1 && <Link href={`?source=${archive ? 'archive' : 'upload'}&page=${page - 1}`}>上一页</Link>}<span>{page} / {Math.max(1, Math.ceil(total / size))}</span>{page * size < total && <Link href={`?source=${archive ? 'archive' : 'upload'}&page=${page + 1}`}>下一页</Link>}</div>
  </div>;
}
