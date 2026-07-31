import { notFound } from 'next/navigation';
import { prisma } from '@/lib/db';
import { tr } from '@/lib/content';
import { saveNews } from '@/app/admin/actions';
import { ImageUpload } from '@/components/admin/ImageUpload';

export default async function NewsEditPage({ params }: { params: { id?: string[] } }) {
  const id = params.id?.[0];
  const n = id ? await prisma.news.findUnique({ where: { id } }) : null;
  if (id && !n) notFound();
  const zh = n ? tr<{ title: string; summary?: string; content?: string }>(n.i18n, 'zh') : { title: '', summary: '', content: '' };
  const en = n ? tr<{ title: string; summary?: string; content?: string }>(n.i18n, 'en') : { title: '', summary: '', content: '' };
  const date = n ? new Date(n.publishedAt).toISOString().slice(0, 10) : new Date().toISOString().slice(0, 10);

  return (
    <form action={saveNews} className="max-w-2xl">
      <h1 className="font-heading text-2xl font-bold">{n ? '编辑文章' : '新增文章'}</h1>
      {n && <input type="hidden" name="id" value={n.id} />}
      <div className="mt-5 card-uten space-y-4 p-5">
        <div className="grid gap-4 sm:grid-cols-2">
          <div><label className="label-uten">分类</label>
            <select name="category" defaultValue={n?.category || 'company'} className="input-uten">
              <option value="company">公司动态</option>
              <option value="industry">行业资讯</option>
            </select>
          </div>
          <div><label className="label-uten">发布日期</label><input type="date" name="publishedAt" defaultValue={date} className="input-uten" /></div>
        </div>
        <div><label className="label-uten">封面图片</label><ImageUpload name="coverImage" value={n?.coverImage || ''} /></div>
      </div>
      <fieldset className="mt-5 card-uten space-y-3 border-l-4 border-l-accent p-5">
        <legend className="px-2 text-sm font-bold text-accent">中文</legend>
        <div><label className="label-uten">标题 *</label><input name="zh_title" required defaultValue={zh.title} className="input-uten" /></div>
        <div><label className="label-uten">摘要</label><input name="zh_summary" defaultValue={zh.summary} className="input-uten" /></div>
        <div><label className="label-uten">正文</label><textarea name="zh_content" rows={6} defaultValue={zh.content} className="input-uten resize-none" /></div>
      </fieldset>
      <fieldset className="mt-5 card-uten space-y-3 border-l-4 border-l-accent p-5">
        <legend className="px-2 text-sm font-bold text-accent">English</legend>
        <div><label className="label-uten">Title</label><input name="en_title" defaultValue={en.title} className="input-uten" /></div>
        <div><label className="label-uten">Summary</label><input name="en_summary" defaultValue={en.summary} className="input-uten" /></div>
        <div><label className="label-uten">Content</label><textarea name="en_content" rows={6} defaultValue={en.content} className="input-uten resize-none" /></div>
      </fieldset>
      <div className="mt-6 flex gap-3"><button className="btn-accent">保存文章</button><a href="/admin/news" className="btn-outline">取消</a></div>
    </form>
  );
}
