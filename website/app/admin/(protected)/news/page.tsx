import Link from 'next/link';
import { prisma } from '@/lib/db';
import { tr, formatDate } from '@/lib/content';
import { deleteNews } from '@/app/admin/actions';
import { DeleteButton } from '@/components/admin/DeleteButton';
import { Plus } from 'lucide-react';

export default async function NewsAdmin() {
  const news = await prisma.news.findMany({ orderBy: { publishedAt: 'desc' } });
  return (
    <div>
      <div className="flex items-center justify-between">
        <h1 className="font-heading text-2xl font-bold">新闻资讯</h1>
        <Link href="/admin/news/edit" className="btn-accent btn-sm"><Plus className="h-4 w-4" />新增文章</Link>
      </div>
      <div className="mt-6 card-uten overflow-x-auto">
        <table className="w-full text-sm">
          <thead className="bg-muted text-left text-xs uppercase text-muted-foreground"><tr><th className="p-3">标题</th><th className="p-3">分类</th><th className="p-3">发布日期</th><th className="p-3 text-right">操作</th></tr></thead>
          <tbody>
            {news.map((n) => (
              <tr key={n.id} className="border-t border-border hover:bg-muted/30">
                <td className="p-3 font-medium">{tr<{ title: string }>(n.i18n, 'zh').title}</td>
                <td className="p-3 text-muted-foreground">{n.category === 'industry' ? '行业资讯' : '公司动态'}</td>
                <td className="p-3 text-muted-foreground">{formatDate(n.publishedAt, 'zh')}</td>
                <td className="whitespace-nowrap p-3 text-right">
                  <Link href={`/admin/news/edit/${n.id}`} className="text-accent hover:underline">编辑</Link>
                  <span className="mx-2 text-border">|</span>
                  <DeleteButton action={() => deleteNews(n.id)} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
