import Link from 'next/link';
import { prisma } from '@/lib/db';
import { requireCmsPermission } from '@/lib/auth';
import { formatDate } from '@/lib/content';
export default async function InquiriesAdmin({ searchParams }: { searchParams: Promise<{ page?: string }> }) {
  await requireCmsPermission('webinquiry:view');
  const query = await searchParams; const page = Math.max(1, Math.trunc(Number(query.page) || 1));
  const [inquiries, total] = await Promise.all([prisma.inquiry.findMany({ orderBy: [{ createdAt: 'desc' }, { id: 'asc' }], skip: (page - 1) * 30, take: 30, include: { delivery: true } }), prisma.inquiry.count()]);
  return <div className="max-w-6xl"><h1 className="text-2xl font-semibold">询盘送达</h1><p className="mt-3 text-sm leading-7 text-muted-foreground">共 {total} 条受理记录。此处核对官网保存与 IMP 入库回执；认领、分配、跟进和转客户请在 IMP 销售工作台办理。</p>
    <div className="mt-7 space-y-4">{inquiries.map(i => <article key={i.id} className="rounded-lg border border-border bg-card p-5"><div className="flex flex-wrap items-start justify-between gap-3"><div><h2 className="font-semibold">{i.company || i.name}</h2><p className="mt-1 text-sm text-muted-foreground">{i.name} · {[i.phone, i.email].filter(Boolean).join(' / ')}</p></div><span className={`rounded px-3 py-1 text-xs ${i.delivery?.state === 'ACKNOWLEDGED' ? 'bg-accent/10 text-accent' : 'bg-amber-50 text-amber-800'}`}>{i.delivery?.state === 'ACKNOWLEDGED' ? 'IMP 已接收' : i.delivery ? '等待同步到 IMP' : '历史记录 · 未自动投递'}</span></div>
      <p className="mt-4 whitespace-pre-line rounded bg-muted/40 p-4 text-sm">{i.message}</p><dl className="mt-4 grid gap-3 text-xs text-muted-foreground sm:grid-cols-2"><div><dt>官网受理编号</dt><dd className="mt-1 break-all text-foreground">{i.id}</dd></div><div><dt>受理时间</dt><dd className="mt-1 text-foreground">{formatDate(i.createdAt, 'zh')}</dd></div>{i.delivery?.erpInquiryId && <div><dt>IMP 记录编号</dt><dd className="mt-1 break-all text-foreground">{i.delivery.erpInquiryId}</dd></div>}{i.productInterest && <div><dt>关注产品</dt><dd className="mt-1 text-foreground">{i.productInterest}</dd></div>}</dl></article>)}{!inquiries.length && <p className="rounded-lg border border-border p-10 text-center text-sm text-muted-foreground">暂无官网询盘。客户提交需求后会在此记录受理与送达状态。</p>}</div>
    <div className="mt-6 flex items-center gap-5 text-sm">{page > 1 && <Link href={`?page=${page - 1}`}>上一页</Link>}<span>{page} / {Math.max(1, Math.ceil(total / 30))}</span>{page * 30 < total && <Link href={`?page=${page + 1}`}>下一页</Link>}</div>
  </div>;
}
