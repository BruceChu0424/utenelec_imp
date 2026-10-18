import Link from 'next/link';
import { prisma } from '@/lib/db';
import { requireCmsPermission, hasCmsPermission } from '@/lib/auth';
import { Package, Newspaper, FileText, History, Inbox, ArrowUpRight } from 'lucide-react';
export default async function AdminDashboard() {
  const session = await requireCmsPermission('website:view');
  const [products, news, resources, drafts, latest, pending] = await Promise.all([
    prisma.product.count({ where: { published: true } }), prisma.news.count({ where: { published: true } }),
    prisma.resourceDocument.count({ where: { published: true } }),
    prisma.cmsRevision.count({ where: { status: 'DRAFT', ...(hasCmsPermission(session, 'website:publish') ? {} : { createdBy: session.actorId || session.username }) } }),
    prisma.cmsRevision.findFirst({ where: { status: 'PUBLISHED' }, orderBy: { publishedAt: 'desc' } }),
    hasCmsPermission(session, 'webinquiry:view') ? prisma.inquiryDelivery.count({ where: { state: 'PENDING' } }) : Promise.resolve(null),
  ]);
  const cards = [
    { title: '已发布产品', value: products, icon: Package, href: '/admin/products', permission: 'website:product_edit' },
    { title: '已发布资讯', value: news, icon: Newspaper, href: '/admin/news', permission: 'website:content_edit' },
    { title: '可下载资料', value: resources, icon: FileText, href: '/admin/resources', permission: 'website:media_manage' },
    { title: '待审查草稿', value: drafts, icon: History, href: '/admin/releases', permission: 'website:view' },
  ];
  return <div className="max-w-6xl"><div className="flex flex-wrap items-end justify-between gap-5"><div><h1 className="text-3xl font-semibold tracking-tight">官网运营</h1><p className="mt-3 text-sm leading-7 text-muted-foreground">维护公司与产品展示，检查内容版本和咨询送达。销售办理在 IMP 工作台完成。</p></div><Link className="btn-outline" href="/zh" target="_blank">查看官网 <ArrowUpRight className="h-4 w-4" /></Link></div>
    <div className="mt-8 grid gap-4 sm:grid-cols-2 xl:grid-cols-4">{cards.filter(c => hasCmsPermission(session, c.permission)).map(c => <Link key={c.title} href={c.href} className="rounded-lg border border-border bg-card p-5"><c.icon className="h-5 w-5 text-accent" /><p className="mt-5 text-3xl font-semibold tabular-nums">{c.value}</p><p className="mt-1 text-sm text-muted-foreground">{c.title}</p></Link>)}</div>
    <div className="mt-7 grid gap-6 lg:grid-cols-2"><section className="rounded-lg border border-border bg-card p-6"><h2 className="text-lg font-semibold">内容发布</h2><p className="mt-3 text-sm leading-7 text-muted-foreground">编辑内容会先保存成草稿。检查具体版本后，再由具备发布权限的员工发布；已发布内容支持版本追溯。</p><p className="my-5 text-sm">最近发布：{latest ? latest.title : '尚无版本发布记录'}</p><Link className="btn-outline" href="/admin/releases">查看草稿与发布</Link></section>
    <section className="rounded-lg border border-border bg-card p-6"><h2 className="flex items-center gap-2 text-lg font-semibold"><Inbox className="h-5 w-5 text-accent" />询盘送达</h2><p className="mt-3 text-sm leading-7 text-muted-foreground">官网先持久保存客户需求，IMP 接收后回传确认。网络中断期间待投递记录会保留。</p>{pending !== null ? <><p className="my-5 text-sm">等待 IMP 接收：<strong>{pending}</strong> 条</p><Link className="btn-outline" href="/admin/inquiries">查看送达记录</Link></> : <p className="mt-5 text-sm text-muted-foreground">销售询盘信息由具有询盘查看权限的员工访问。</p>}</section></div>
  </div>;
}
