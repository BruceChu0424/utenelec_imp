import { notFound } from 'next/navigation';
import { prisma } from '@/lib/db';
import { tr } from '@/lib/content';
import { saveSeries } from '@/app/admin/actions';

export default async function SeriesEditPage({ params }: { params: { id?: string[] } }) {
  const id = params.id?.[0];
  const s = id ? await prisma.series.findUnique({ where: { id } }) : null;
  if (id && !s) notFound();
  const zh = s ? tr<{ name: string; description?: string }>(s.i18n, 'zh') : { name: '', description: '' };
  const en = s ? tr<{ name: string; description?: string }>(s.i18n, 'en') : { name: '', description: '' };

  return (
    <form action={saveSeries} className="max-w-2xl">
      <h1 className="font-heading text-2xl font-bold">{s ? '编辑系列' : '新增系列'}</h1>
      {s && <input type="hidden" name="id" value={s.id} />}
      <div className="mt-5 card-uten space-y-4 p-5">
        <div className="grid gap-4 sm:grid-cols-2">
          <div><label className="label-uten">代号 (英文, 用于网址) *</label><input name="code" required defaultValue={s?.code || ''} className="input-uten font-mono" placeholder="如 z9、s300" /></div>
          <div><label className="label-uten">排序 (数字越小越靠前)</label><input name="sortOrder" type="number" defaultValue={s?.sortOrder ?? 0} className="input-uten" /></div>
        </div>
      </div>
      <fieldset className="mt-5 card-uten space-y-3 border-l-4 border-l-accent p-5">
        <legend className="px-2 text-sm font-bold text-accent">中文</legend>
        <div><label className="label-uten">系列名称 *</label><input name="zh_name" required defaultValue={zh.name} className="input-uten" /></div>
        <div><label className="label-uten">系列描述</label><textarea name="zh_desc" rows={3} defaultValue={zh.description} className="input-uten resize-none" /></div>
      </fieldset>
      <fieldset className="mt-5 card-uten space-y-3 border-l-4 border-l-accent p-5">
        <legend className="px-2 text-sm font-bold text-accent">English</legend>
        <div><label className="label-uten">Series Name</label><input name="en_name" defaultValue={en.name} className="input-uten" /></div>
        <div><label className="label-uten">Description</label><textarea name="en_desc" rows={3} defaultValue={en.description} className="input-uten resize-none" /></div>
      </fieldset>
      <div className="mt-6 flex gap-3"><button className="btn-accent">保存系列</button><a href="/admin/series" className="btn-outline">取消</a></div>
    </form>
  );
}
