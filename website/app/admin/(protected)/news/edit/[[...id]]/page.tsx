import { notFound } from 'next/navigation';
import Link from 'next/link';
import { prisma } from '@/lib/db';
import { pickLocale } from '@/lib/content';
import { saveNews } from '@/app/admin/actions';
import { ImageUpload } from '@/components/admin/ImageUpload';

export default async function NewsEditPage({ params }: { params: Promise<{ id?: string[] }> }) {
  const id = (await params).id?.[0];
  const n = id ? await prisma.news.findUnique({ where: { id } }) : null;
  if (id && !n) notFound();
  const zh = n ? (pickLocale<{ title?: string; summary?: string; content?: string }>(n.i18n, 'zh') ?? {}) : {};
  const en = n ? (pickLocale<{ title?: string; summary?: string; content?: string }>(n.i18n, 'en') ?? {}) : {};
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
              <option value="guide">采购指南</option>
            </select>
          </div>
          <div><label className="label-uten">发布日期</label><input type="date" name="publishedAt" defaultValue={date} className="input-uten" /></div>
        </div>
        <div><label className="label-uten">封面图片</label><ImageUpload name="coverImage" value={n?.coverImage || ''} /></div>
      </div>
      <p id="article-syntax-help" className="mt-4 rounded-2xl border border-border bg-muted/45 px-4 py-3 text-sm leading-6 text-muted-foreground">
        正文支持轻量结构：<code>## 二级标题</code>、<code>- 列表项</code>，段落之间留一个空行。系统只显示纯文本，不解析 HTML。
      </p>
      <fieldset className="mt-5 card-uten space-y-3 border-l-4 border-l-accent p-5">
        <legend className="px-2 text-sm font-bold text-accent">中文</legend>
        <div><label className="label-uten">标题 *</label><input name="zh_title" required defaultValue={zh.title || ''} className="input-uten" /></div>
        <div><label className="label-uten">摘要</label><input name="zh_summary" defaultValue={zh.summary || ''} className="input-uten" /></div>
        <div><label className="label-uten">正文</label><textarea name="zh_content" rows={14} defaultValue={zh.content || ''} aria-describedby="article-syntax-help" className="input-uten min-h-80 resize-y" /></div>
      </fieldset>
      <fieldset className="mt-5 card-uten space-y-3 border-l-4 border-l-accent p-5">
        <legend className="px-2 text-sm font-bold text-accent">English</legend>
        <div><label className="label-uten">Title</label><input name="en_title" defaultValue={en.title || ''} className="input-uten" /></div>
        <div><label className="label-uten">Summary</label><input name="en_summary" defaultValue={en.summary || ''} className="input-uten" /></div>
        <div><label className="label-uten">Content</label><textarea name="en_content" rows={14} defaultValue={en.content || ''} aria-describedby="article-syntax-help" className="input-uten min-h-80 resize-y" /></div>
      </fieldset>
      <div className="mt-6 flex gap-3"><button className="btn-accent">保存文章</button><Link href="/admin/news" className="btn-outline">取消</Link></div>
    </form>
  );
}
