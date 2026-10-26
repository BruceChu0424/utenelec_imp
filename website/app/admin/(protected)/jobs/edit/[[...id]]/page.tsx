import { notFound } from 'next/navigation';
import Link from 'next/link';
import type { Job } from '@prisma/client';
import { getCmsEditState } from '@/lib/cms-revisions';
import { CmsDraftForm } from '@/components/admin/CmsDraftForm';
import { pickLocale } from '@/lib/content';
import { saveJob } from '@/app/admin/actions';
import { PublicationField } from '@/components/admin/PublicationField';

export default async function JobEditPage({ params }: { params: Promise<{ id?: string[] }> }) {
  const id = (await params).id?.[0];
  const editing = id ? await getCmsEditState('job', id) : null;
  const j = editing?.snapshot.record as unknown as Job | null;
  if (id && !j) notFound();
  const zh = j ? (pickLocale<{ title?: string; requirements?: string; description?: string }>(j.i18n, 'zh') ?? {}) : {};
  const en = j ? (pickLocale<{ title?: string; requirements?: string; description?: string }>(j.i18n, 'en') ?? {}) : {};

  return (
    <CmsDraftForm action={saveJob} className="max-w-2xl">
      <h1 className="font-heading text-2xl font-bold">{j ? '编辑岗位' : '新增岗位'}</h1>
      {j && <input type="hidden" name="id" value={j.id} />}
      <input type="hidden" name="expectedHash" value={editing?.baseHash || ''} />
      <div className="mt-5 card-uten space-y-4 p-5">
        <div className="grid gap-4 sm:grid-cols-2">
          <div><label htmlFor="job-department" className="label-uten">所属部门</label><input id="job-department" name="department" defaultValue={j?.department || ''} className="input-uten" /></div>
          <div><label htmlFor="job-location" className="label-uten">工作地点</label><input id="job-location" name="location" defaultValue={j?.location || ''} className="input-uten" /></div>
        </div>
        <PublicationField id="job-published" published={j?.published ?? false} />
      </div>
      <fieldset className="mt-5 card-uten space-y-3 border-l-4 border-l-accent p-5">
        <legend className="px-2 text-sm font-bold text-accent">中文</legend>
        <div><label htmlFor="job-zh-title" className="label-uten">岗位名称 *</label><input id="job-zh-title" name="zh_title" required defaultValue={zh.title || ''} className="input-uten" /></div>
        <div><label htmlFor="job-zh-description" className="label-uten">岗位描述</label><textarea id="job-zh-description" name="zh_description" rows={3} defaultValue={zh.description || ''} className="input-uten resize-none" /></div>
        <div><label htmlFor="job-zh-requirements" className="label-uten">任职要求 (每行一条)</label><textarea id="job-zh-requirements" name="zh_requirements" rows={5} defaultValue={zh.requirements || ''} className="input-uten resize-none" /></div>
      </fieldset>
      <fieldset className="mt-5 card-uten space-y-3 border-l-4 border-l-accent p-5">
        <legend className="px-2 text-sm font-bold text-accent">English</legend>
        <div><label htmlFor="job-en-title" className="label-uten">Title</label><input id="job-en-title" name="en_title" defaultValue={en.title || ''} className="input-uten" /></div>
        <div><label htmlFor="job-en-description" className="label-uten">Description</label><textarea id="job-en-description" name="en_description" rows={3} defaultValue={en.description || ''} className="input-uten resize-none" /></div>
        <div><label htmlFor="job-en-requirements" className="label-uten">Requirements</label><textarea id="job-en-requirements" name="en_requirements" rows={5} defaultValue={en.requirements || ''} className="input-uten resize-none" /></div>
      </fieldset>
      <div className="mt-6 flex gap-3"><button className="btn-accent">保存岗位</button><Link href="/admin/jobs" className="btn-outline">取消</Link></div>
    </CmsDraftForm>
  );
}
