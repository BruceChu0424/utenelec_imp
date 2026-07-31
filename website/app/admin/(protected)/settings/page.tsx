import { prisma } from '@/lib/db';
import { pick } from '@/lib/content';
import { saveHero, saveContact } from '@/app/admin/actions';

export default async function SettingsPage() {
  const [heroR, contactR] = await Promise.all([
    prisma.setting.findUnique({ where: { key: 'hero' } }),
    prisma.setting.findUnique({ where: { key: 'contact' } }),
  ]);
  const h = (l: string) => pick<Record<string, string>>(heroR?.i18n, l) || {};
  const c = (l: string) => pick<Record<string, string>>(contactR?.i18n, l) || {};

  return (
    <div className="max-w-2xl">
      <h1 className="font-heading text-2xl font-bold">站点设置</h1>

      <form action={saveHero} className="mt-6">
        <h2 className="mb-3 font-semibold">首页标语 (Hero)</h2>
        <fieldset className="card-uten space-y-3 border-l-4 border-l-accent p-5">
          <legend className="px-2 text-sm font-bold text-accent">中文</legend>
          <div><label className="label-uten">主标题</label><input name="zh_title" defaultValue={h('zh').title} className="input-uten" /></div>
          <div><label className="label-uten">副标题</label><input name="zh_subtitle" defaultValue={h('zh').subtitle} className="input-uten" /></div>
          <div className="grid gap-3 sm:grid-cols-2">
            <div><label className="label-uten">按钮1</label><input name="zh_cta1" defaultValue={h('zh').cta1} className="input-uten" /></div>
            <div><label className="label-uten">按钮2</label><input name="zh_cta2" defaultValue={h('zh').cta2} className="input-uten" /></div>
          </div>
        </fieldset>
        <fieldset className="mt-3 card-uten space-y-3 border-l-4 border-l-accent p-5">
          <legend className="px-2 text-sm font-bold text-accent">English</legend>
          <div><label className="label-uten">Title</label><input name="en_title" defaultValue={h('en').title} className="input-uten" /></div>
          <div><label className="label-uten">Subtitle</label><input name="en_subtitle" defaultValue={h('en').subtitle} className="input-uten" /></div>
          <div className="grid gap-3 sm:grid-cols-2">
            <div><label className="label-uten">Button 1</label><input name="en_cta1" defaultValue={h('en').cta1} className="input-uten" /></div>
            <div><label className="label-uten">Button 2</label><input name="en_cta2" defaultValue={h('en').cta2} className="input-uten" /></div>
          </div>
        </fieldset>
        <button className="btn-accent mt-4">保存首页标语</button>
      </form>

      <form action={saveContact} className="mt-10">
        <h2 className="mb-3 font-semibold">联系方式 (Contact)</h2>
        <fieldset className="card-uten space-y-3 border-l-4 border-l-accent p-5">
          <legend className="px-2 text-sm font-bold text-accent">中文</legend>
          <div><label className="label-uten">公司名称</label><input name="zh_company" defaultValue={c('zh').company} className="input-uten" /></div>
          <div className="grid gap-3 sm:grid-cols-2">
            <div><label className="label-uten">电话</label><input name="zh_phone" defaultValue={c('zh').phone} className="input-uten" /></div>
            <div><label className="label-uten">电话2</label><input name="zh_phone2" defaultValue={c('zh').phone2} className="input-uten" /></div>
          </div>
          <div><label className="label-uten">邮箱</label><input name="zh_email" defaultValue={c('zh').email} className="input-uten" /></div>
          <div><label className="label-uten">地址</label><input name="zh_address" defaultValue={c('zh').address} className="input-uten" /></div>
          <div><label className="label-uten">备案号</label><input name="zh_icp" defaultValue={c('zh').icp} className="input-uten" /></div>
        </fieldset>
        <fieldset className="mt-3 card-uten space-y-3 border-l-4 border-l-accent p-5">
          <legend className="px-2 text-sm font-bold text-accent">English</legend>
          <div><label className="label-uten">Company</label><input name="en_company" defaultValue={c('en').company} className="input-uten" /></div>
          <div className="grid gap-3 sm:grid-cols-2">
            <div><label className="label-uten">Phone</label><input name="en_phone" defaultValue={c('en').phone} className="input-uten" /></div>
            <div><label className="label-uten">Phone 2</label><input name="en_phone2" defaultValue={c('en').phone2} className="input-uten" /></div>
          </div>
          <div><label className="label-uten">Email</label><input name="en_email" defaultValue={c('en').email} className="input-uten" /></div>
          <div><label className="label-uten">Address</label><input name="en_address" defaultValue={c('en').address} className="input-uten" /></div>
        </fieldset>
        <button className="btn-accent mt-4">保存联系方式</button>
      </form>
    </div>
  );
}
