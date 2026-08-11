import { notFound } from 'next/navigation';
import Link from 'next/link';
import { prisma } from '@/lib/db';
import { pickLocale } from '@/lib/content';
import { saveCase } from '@/app/admin/actions';
import { ImageUpload } from '@/components/admin/ImageUpload';

export default async function CaseEditPage({ params }: { params: Promise<{ id?: string[] }> }) {
  const id = (await params).id?.[0];
  const c = id ? await prisma.caseItem.findUnique({ where: { id } }) : null;
  if (id && !c) notFound();
  const zh = c ? (pickLocale<{ title?: string; location?: string; content?: string }>(c.i18n, 'zh') ?? {}) : {};
  const en = c ? (pickLocale<{ title?: string; location?: string; content?: string }>(c.i18n, 'en') ?? {}) : {};

  return (
    <form action={saveCase} className="max-w-2xl">
      <h1 className="font-heading text-2xl font-bold">{c ? '编辑案例' : '新增案例'}</h1>
      {c && <input type="hidden" name="id" value={c.id} />}
      <div className="mt-5 card-uten space-y-4 p-5">
        <div><label className="label-uten">封面图片</label><ImageUpload name="coverImage" value={c?.coverImage || ''} /></div>
      </div>
      <fieldset className="mt-5 card-uten space-y-3 border-l-4 border-l-accent p-5">
        <legend className="px-2 text-sm font-bold text-accent">中文</legend>
        <div><label className="label-uten">项目名称 *</label><input name="zh_title" required defaultValue={zh.title || ''} className="input-uten" /></div>
        <div><label className="label-uten">地点</label><input name="zh_location" defaultValue={zh.location || ''} className="input-uten" /></div>
        <div><label className="label-uten">项目描述</label><textarea name="zh_content" rows={4} defaultValue={zh.content || ''} className="input-uten resize-none" /></div>
      </fieldset>
      <fieldset className="mt-5 card-uten space-y-3 border-l-4 border-l-accent p-5">
        <legend className="px-2 text-sm font-bold text-accent">English</legend>
        <div><label className="label-uten">Title</label><input name="en_title" defaultValue={en.title || ''} className="input-uten" /></div>
        <div><label className="label-uten">Location</label><input name="en_location" defaultValue={en.location || ''} className="input-uten" /></div>
        <div><label className="label-uten">Description</label><textarea name="en_content" rows={4} defaultValue={en.content || ''} className="input-uten resize-none" /></div>
      </fieldset>
      <div className="mt-6 flex gap-3"><button className="btn-accent">保存案例</button><Link href="/admin/cases" className="btn-outline">取消</Link></div>
    </form>
  );
}
