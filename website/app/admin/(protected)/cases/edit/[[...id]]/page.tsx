import { notFound } from 'next/navigation';
import Link from 'next/link';
import type { CaseItem } from '@prisma/client';
import { getCmsEditState } from '@/lib/cms-revisions';
import { CmsDraftForm } from '@/components/admin/CmsDraftForm';
import { pickLocale } from '@/lib/content';
import { saveCase } from '@/app/admin/actions';
import { ImageUpload } from '@/components/admin/ImageUpload';
import { PublicationField } from '@/components/admin/PublicationField';

export default async function CaseEditPage({ params }: { params: Promise<{ id?: string[] }> }) {
  const id = (await params).id?.[0];
  const editing = id ? await getCmsEditState('case', id) : null;
  const c = editing?.snapshot.record as unknown as CaseItem | null;
  if (id && !c) notFound();
  const zh = c ? (pickLocale<{ title?: string; location?: string; content?: string }>(c.i18n, 'zh') ?? {}) : {};
  const en = c ? (pickLocale<{ title?: string; location?: string; content?: string }>(c.i18n, 'en') ?? {}) : {};

  return (
    <CmsDraftForm action={saveCase} className="max-w-2xl">
      <h1 className="font-heading text-2xl font-bold">{c ? '编辑案例' : '新增案例'}</h1>
      {c && <input type="hidden" name="id" value={c.id} />}
      <input type="hidden" name="expectedHash" value={editing?.baseHash || ''} />
      <div className="mt-5 card-uten space-y-4 p-5">
        <div><label htmlFor="case-cover-image" className="label-uten">封面图片</label><ImageUpload id="case-cover-image" name="coverImage" value={c?.coverImage || ''} /></div>
        <PublicationField id="case-published" published={c?.published ?? false} />
      </div>
      <fieldset className="mt-5 card-uten space-y-3 border-l-4 border-l-accent p-5">
        <legend className="px-2 text-sm font-bold text-accent">中文</legend>
        <div><label htmlFor="case-zh-title" className="label-uten">项目名称 *</label><input id="case-zh-title" name="zh_title" required defaultValue={zh.title || ''} className="input-uten" /></div>
        <div><label htmlFor="case-zh-location" className="label-uten">地点</label><input id="case-zh-location" name="zh_location" defaultValue={zh.location || ''} className="input-uten" /></div>
        <div><label htmlFor="case-zh-content" className="label-uten">项目描述</label><textarea id="case-zh-content" name="zh_content" rows={4} defaultValue={zh.content || ''} className="input-uten resize-none" /></div>
      </fieldset>
      <fieldset className="mt-5 card-uten space-y-3 border-l-4 border-l-accent p-5">
        <legend className="px-2 text-sm font-bold text-accent">English</legend>
        <div><label htmlFor="case-en-title" className="label-uten">Title</label><input id="case-en-title" name="en_title" defaultValue={en.title || ''} className="input-uten" /></div>
        <div><label htmlFor="case-en-location" className="label-uten">Location</label><input id="case-en-location" name="en_location" defaultValue={en.location || ''} className="input-uten" /></div>
        <div><label htmlFor="case-en-content" className="label-uten">Description</label><textarea id="case-en-content" name="en_content" rows={4} defaultValue={en.content || ''} className="input-uten resize-none" /></div>
      </fieldset>
      <div className="mt-6 flex gap-3"><button className="btn-accent">保存案例草稿</button><Link href="/admin/cases" className="btn-outline">取消</Link></div>
    </CmsDraftForm>
  );
}
