import { prisma } from '@/lib/db';
import { formatDate } from '@/lib/content';
import { handleInquiry, deleteInquiry } from '@/app/admin/actions';
import { DeleteButton } from '@/components/admin/DeleteButton';

export default async function InquiriesAdmin() {
  const inquiries = await prisma.inquiry.findMany({ orderBy: { createdAt: 'desc' } });
  return (
    <div>
      <h1 className="font-heading text-2xl font-bold">客户留言</h1>
      <p className="text-sm text-muted-foreground">共 {inquiries.length} 条 · 来自前台联系、国际合作与产品表单</p>
      <div className="mt-6 space-y-3">
        {inquiries.length === 0 && <p className="card-uten p-10 text-center text-muted-foreground">暂无留言</p>}
        {inquiries.map((i) => (
          <div key={i.id} className={`card-uten p-5 ${i.handled ? 'opacity-60' : 'border-l-4 border-l-accent'}`}>
            <div className="flex flex-wrap items-start justify-between gap-3">
              <div>
                <p className="font-semibold">{i.name} {i.company && <span className="font-normal text-muted-foreground">· {i.company}</span>}</p>
                <p className="mt-0.5 text-sm text-muted-foreground">
                  {[i.phone, i.email].filter(Boolean).join(' / ') || '未留联系方式'} · 来源:{i.source === 'partner' ? '国际合作' : i.source === 'join' ? '招商' : i.source === 'product' ? '产品' : i.source === 'studio' ? '试装' : '联系'} · {formatDate(i.createdAt, 'zh')}
                </p>
              </div>
              {!i.handled ? (
                <form action={handleInquiry.bind(null, i.id)}><button className="btn-outline btn-sm">标记已处理</button></form>
              ) : (
                <span className="chip">已处理</span>
              )}
            </div>
            {[i.market, i.customerType, i.requiredStandard, i.productInterest, i.requestType, i.estimatedQuantity, i.targetSchedule, i.preferredContact].some(Boolean) && (
              <dl className="mt-4 grid gap-3 rounded-xl border border-border bg-background-elevated/55 p-4 text-sm sm:grid-cols-2 lg:grid-cols-4">
                {[
                  ['目标市场', i.market], ['客户类型', i.customerType], ['标准/安装体系', i.requiredStandard], ['关注产品', i.productInterest],
                  ['需求类型', i.requestType], ['预计数量', i.estimatedQuantity], ['目标时间', i.targetSchedule], ['首选联系', i.preferredContact],
                ].filter((entry): entry is [string, string] => Boolean(entry[1])).map(([label, value]) => <div key={label}><dt className="text-xs text-muted-foreground">{label}</dt><dd className="mt-1 font-medium">{value}</dd></div>)}
              </dl>
            )}
            <p className="mt-3 whitespace-pre-line rounded-lg bg-muted/40 p-3 text-sm">{i.message}</p>
            <div className="mt-3 text-right"><DeleteButton action={deleteInquiry.bind(null, i.id)} /></div>
          </div>
        ))}
      </div>
    </div>
  );
}
