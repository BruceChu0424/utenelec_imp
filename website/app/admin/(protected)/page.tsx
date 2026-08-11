import Link from 'next/link';
import { prisma } from '@/lib/db';
import { Package, Newspaper, FolderTree, Inbox, Building2, Briefcase } from 'lucide-react';

export default async function AdminDashboard() {
  const [products, series, news, cases, jobs, inquiries, unhandled] = await Promise.all([
    prisma.product.count(), prisma.series.count(), prisma.news.count(),
    prisma.caseItem.count(), prisma.job.count(), prisma.inquiry.count(),
    prisma.inquiry.count({ where: { handled: false } }),
  ]);
  const cards = [
    { label: '产品', value: products, icon: Package, href: '/admin/products' },
    { label: '产品系列', value: series, icon: FolderTree, href: '/admin/series' },
    { label: '新闻资讯', value: news, icon: Newspaper, href: '/admin/news' },
    { label: '样板工程', value: cases, icon: Building2, href: '/admin/cases' },
    { label: '招聘岗位', value: jobs, icon: Briefcase, href: '/admin/jobs' },
    { label: '客户留言', value: inquiries, icon: Inbox, href: '/admin/inquiries' },
  ];
  return (
    <div>
      <h1 className="font-heading text-2xl font-bold">仪表盘</h1>
      {unhandled > 0 && (
        <Link href="/admin/inquiries" className="mt-4 block rounded-lg bg-accent/10 px-4 py-3 text-sm text-accent transition hover:bg-accent/15">
          🔔 您有 {unhandled} 条新留言待处理 →
        </Link>
      )}
      <div className="mt-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {cards.map((c) => (
          <Link key={c.href} href={c.href} className="card-uten flex items-center gap-4 p-5 transition hover:-translate-y-0.5 hover:shadow-md">
            <span className="grid h-12 w-12 place-items-center rounded-xl bg-accent/10 text-accent">
              <c.icon className="h-5 w-5" />
            </span>
            <div>
              <p className="font-heading text-2xl font-bold">{c.value}</p>
              <p className="text-sm text-muted-foreground">{c.label}</p>
            </div>
          </Link>
        ))}
      </div>

      <div className="mt-8 card-uten p-6">
        <h2 className="font-semibold">快速入门</h2>
        <ol className="mt-3 list-decimal space-y-1.5 pl-5 text-sm text-muted-foreground">
          <li>在「产品管理」新增或编辑产品，可上传图片；填写中英文信息即可。</li>
          <li>「产品系列」管理导航与产品分类。</li>
          <li>「新闻资讯」「样板工程」「人才招聘」同理，均支持中英文。</li>
          <li>「站点设置」修改首页标语与联系方式。</li>
          <li>「客户留言」查看前台表单提交的咨询。</li>
        </ol>
      </div>
    </div>
  );
}
