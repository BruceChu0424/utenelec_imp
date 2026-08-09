'use client';

import { useRef, useState, type ReactNode } from 'react';
import { useFormStatus } from 'react-dom';
import { ArrowDown, ArrowUp, ImageIcon, Loader2, Plus, Save, Settings2, Trash2 } from 'lucide-react';
import { saveSiteSetting } from '@/app/admin/actions';
import { ImageUpload } from './ImageUpload';

export type SiteSettingKey = 'hero' | 'contact' | 'about' | 'stats' | 'craft' | 'join' | 'capabilities' | 'partners' | 'resources' | 'careers' | 'footer';
type LocaleObject = Record<string, string>;
type SettingRow = Record<string, string>;
type JoinContent = { title?: string; subtitle?: string; advantages?: string[]; cta?: string };

export type SiteSettingsInitial = {
  hero: { zh: LocaleObject; en: LocaleObject };
  contact: { zh: LocaleObject; en: LocaleObject };
  about: { zh: LocaleObject; en: LocaleObject };
  stats: { zh: SettingRow[]; en: SettingRow[] };
  craft: { zh: SettingRow[]; en: SettingRow[] };
  join: { zh: JoinContent; en: JoinContent };
  capabilities: { zh: LocaleObject; en: LocaleObject };
  partners: { zh: LocaleObject; en: LocaleObject };
  resources: { zh: LocaleObject; en: LocaleObject };
  careers: { zh: LocaleObject; en: LocaleObject };
  footer: { zh: LocaleObject; en: LocaleObject };
};

type EditableRow = SettingRow & { key: string };

function TextField({
  id,
  name,
  label,
  value = '',
  maxLength,
  required = false,
  type = 'text',
  rows,
  hint,
}: {
  id: string;
  name: string;
  label: string;
  value?: string;
  maxLength: number;
  required?: boolean;
  type?: 'text' | 'email' | 'tel';
  rows?: number;
  hint?: string;
}) {
  return (
    <div>
      <label htmlFor={id} className="label-uten">{label}{required ? ' *' : ''}</label>
      {rows ? (
        <textarea id={id} name={name} rows={rows} maxLength={maxLength} required={required} defaultValue={value} className="input-uten resize-y" />
      ) : (
        <input id={id} name={name} type={type} maxLength={maxLength} required={required} defaultValue={value} className="input-uten" />
      )}
      {hint && <p className="mt-1 text-xs leading-relaxed text-muted-foreground">{hint}</p>}
    </div>
  );
}

function LocalePanel({ locale, children }: { locale: 'zh' | 'en'; children: ReactNode }) {
  return (
    <fieldset className="card-uten space-y-4 border-l-4 border-l-accent p-5">
      <legend className="px-2 text-sm font-bold text-accent">{locale === 'zh' ? '中文' : 'English'}</legend>
      {children}
      {locale === 'en' && (
        <p className="text-xs leading-relaxed text-muted-foreground">
          英文全部留空会保持为“缺失”，不会复制中文制造伪翻译；其他语言不会被本表单删除。
        </p>
      )}
    </fieldset>
  );
}

function SettingSubmitButton({ disabled }: { disabled: boolean }) {
  const { pending } = useFormStatus();
  return (
    <button type="submit" disabled={pending || disabled} className="btn-accent min-h-11 disabled:cursor-not-allowed disabled:opacity-50">
      {pending ? <Loader2 className="h-4 w-4 animate-spin" /> : <Save className="h-4 w-4" />}
      {pending ? '保存中' : '保存本节'}
    </button>
  );
}

function SettingForm({
  settingKey,
  title,
  description,
  invalidReason,
  feedback,
  children,
}: {
  settingKey: SiteSettingKey;
  title: string;
  description: string;
  invalidReason?: string;
  feedback?: { kind: 'success' | 'error'; message: string };
  children: ReactNode;
}) {
  return (
    <form id={`setting-${settingKey}`} action={saveSiteSetting} className="scroll-mt-24 border-t border-border py-9 first:border-t-0 first:pt-0">
      <input type="hidden" name="settingKey" value={settingKey} />
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div className="max-w-2xl">
          <p className="text-xs font-bold uppercase tracking-[.18em] text-accent">{settingKey}</p>
          <h2 className="mt-1 font-heading text-xl font-bold md:text-2xl">{title}</h2>
          <p className="mt-2 text-sm leading-6 text-muted-foreground">{description}</p>
        </div>
        <SettingSubmitButton disabled={Boolean(invalidReason)} />
      </div>

      {invalidReason && (
        <div role="alert" className="mt-4 rounded-xl border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm leading-6 text-destructive">
          现有数据无法安全读取：{invalidReason}。为防止覆盖其他语言，本节已禁止保存，请先修复原始 JSON。
        </div>
      )}
      {feedback && (
        <div
          role={feedback.kind === 'error' ? 'alert' : 'status'}
          aria-live="polite"
          className={`mt-4 rounded-xl px-4 py-3 text-sm ${feedback.kind === 'error' ? 'bg-destructive/10 text-destructive' : 'bg-accent/10 text-accent'}`}
        >
          {feedback.message}
        </div>
      )}
      <div className="mt-5">{children}</div>
    </form>
  );
}

function StructuredListEditor({
  locale,
  group,
  title,
  items,
  fields,
}: {
  locale: 'zh' | 'en';
  group: 'stats' | 'craft';
  title: string;
  items: SettingRow[];
  fields: readonly { name: string; label: string; maxLength: number; placeholder: string }[];
}) {
  const nextKey = useRef(items.length);
  const [rows, setRows] = useState<EditableRow[]>(() => items.map((item, index) => ({ ...item, key: `${locale}-${group}-${index}` })));

  const move = (index: number, direction: -1 | 1) => {
    const target = index + direction;
    if (target < 0 || target >= rows.length) return;
    setRows((current) => {
      const copy = [...current];
      [copy[index], copy[target]] = [copy[target], copy[index]];
      return copy;
    });
  };

  return (
    <LocalePanel locale={locale}>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <p className="text-sm font-semibold">{title}</p>
        <button
          type="button"
          onClick={() => setRows((current) => [...current, { key: `${locale}-${group}-new-${nextKey.current++}` }])}
          className="btn-outline btn-sm min-h-11"
        >
          <Plus className="h-4 w-4" />新增一项
        </button>
      </div>

      {rows.length ? (
        <div className="space-y-3">
          {rows.map((row, index) => (
            <fieldset key={row.key} className="rounded-xl border border-border bg-background/60 p-3">
              <legend className="sr-only">{title}第 {index + 1} 项</legend>
              <div className="grid gap-3 lg:grid-cols-[1fr_1.5fr_auto] lg:items-end">
                {fields.map((field) => (
                  <div key={field.name}>
                    <label htmlFor={`${row.key}-${field.name}`} className="label-uten">{field.label}</label>
                    <input
                      id={`${row.key}-${field.name}`}
                      name={`${locale}_${group}_${field.name}`}
                      maxLength={field.maxLength}
                      defaultValue={row[field.name] || ''}
                      placeholder={field.placeholder}
                      className="input-uten"
                    />
                  </div>
                ))}
                <div className="flex gap-1">
                  <button type="button" onClick={() => move(index, -1)} disabled={index === 0} aria-label={`上移第 ${index + 1} 项`} className="grid h-11 w-11 place-items-center rounded-lg text-muted-foreground transition hover:bg-muted hover:text-foreground disabled:opacity-30"><ArrowUp className="h-4 w-4" /></button>
                  <button type="button" onClick={() => move(index, 1)} disabled={index === rows.length - 1} aria-label={`下移第 ${index + 1} 项`} className="grid h-11 w-11 place-items-center rounded-lg text-muted-foreground transition hover:bg-muted hover:text-foreground disabled:opacity-30"><ArrowDown className="h-4 w-4" /></button>
                  <button type="button" onClick={() => setRows((current) => current.filter((item) => item.key !== row.key))} aria-label={`删除第 ${index + 1} 项`} className="grid h-11 w-11 place-items-center rounded-lg text-destructive transition hover:bg-destructive/10"><Trash2 className="h-4 w-4" /></button>
                </div>
              </div>
            </fieldset>
          ))}
        </div>
      ) : (
        <p className="rounded-xl border border-dashed border-border px-4 py-5 text-center text-sm text-muted-foreground">暂无内容，可点击“新增一项”开始填写。</p>
      )}
    </LocalePanel>
  );
}

function AdvantagesEditor({ locale, items }: { locale: 'zh' | 'en'; items: string[] }) {
  const nextKey = useRef(items.length);
  const [rows, setRows] = useState(() => items.map((value, index) => ({ key: `${locale}-advantage-${index}`, value })));
  const move = (index: number, direction: -1 | 1) => {
    const target = index + direction;
    if (target < 0 || target >= rows.length) return;
    setRows((current) => {
      const copy = [...current];
      [copy[index], copy[target]] = [copy[target], copy[index]];
      return copy;
    });
  };

  return (
    <div>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <p className="label-uten mb-0">合作优势</p>
        <button type="button" onClick={() => setRows((current) => [...current, { key: `${locale}-advantage-new-${nextKey.current++}`, value: '' }])} className="btn-outline btn-sm min-h-11"><Plus className="h-4 w-4" />新增优势</button>
      </div>
      <div className="mt-3 space-y-2">
        {rows.map((row, index) => (
          <div key={row.key} className="grid gap-2 sm:grid-cols-[1fr_auto] sm:items-center">
            <label htmlFor={row.key} className="sr-only">合作优势第 {index + 1} 项</label>
            <input id={row.key} name={`${locale}_advantages`} maxLength={300} defaultValue={row.value} className="input-uten" />
            <div className="flex gap-1">
              <button type="button" onClick={() => move(index, -1)} disabled={index === 0} aria-label={`上移优势 ${index + 1}`} className="grid h-11 w-11 place-items-center rounded-lg text-muted-foreground transition hover:bg-muted disabled:opacity-30"><ArrowUp className="h-4 w-4" /></button>
              <button type="button" onClick={() => move(index, 1)} disabled={index === rows.length - 1} aria-label={`下移优势 ${index + 1}`} className="grid h-11 w-11 place-items-center rounded-lg text-muted-foreground transition hover:bg-muted disabled:opacity-30"><ArrowDown className="h-4 w-4" /></button>
              <button type="button" onClick={() => setRows((current) => current.filter((item) => item.key !== row.key))} aria-label={`删除优势 ${index + 1}`} className="grid h-11 w-11 place-items-center rounded-lg text-destructive transition hover:bg-destructive/10"><Trash2 className="h-4 w-4" /></button>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

export function SiteSettingsForm({
  initial,
  errors,
  feedback,
}: {
  initial: SiteSettingsInitial;
  errors: Partial<Record<SiteSettingKey, string>>;
  feedback?: { key: SiteSettingKey; kind: 'success' | 'error'; message: string };
}) {
  const aboutImages = [1, 2, 3].map((index) => initial.about.zh[`image${index}`] || initial.about.en[`image${index}`] || '');
  const sections: { key: SiteSettingKey; label: string }[] = [
    { key: 'hero', label: '首页首屏' }, { key: 'about', label: '关于我们' }, { key: 'stats', label: '企业数据' },
    { key: 'craft', label: '核心工艺' }, { key: 'contact', label: '联系方式' }, { key: 'join', label: '招商加盟' },
    { key: 'capabilities', label: '国际能力' }, { key: 'partners', label: '国际合作' }, { key: 'resources', label: '专业资料' },
    { key: 'careers', label: '人才招聘' }, { key: 'footer', label: '页脚' },
  ];

  return (
    <div className="max-w-5xl pb-12">
      <div className="flex items-center gap-2 text-accent"><Settings2 className="h-5 w-5" /><p className="text-xs font-bold uppercase tracking-[.18em]">Site content</p></div>
      <h1 className="mt-2 font-heading text-2xl font-bold md:text-3xl">全站内容设置</h1>
      <p className="mt-2 max-w-3xl text-sm leading-6 text-muted-foreground">集中维护公开网站现有的中英文企业内容。每一节独立保存；未展示的其他语言会原样保留。</p>

      <nav aria-label="设置分区" className="mt-6 flex flex-wrap gap-2">
        {sections.map((section) => <a key={section.key} href={`#setting-${section.key}`} className="inline-flex min-h-11 items-center rounded-full border border-border px-4 text-sm font-medium transition hover:border-accent hover:text-accent">{section.label}</a>)}
      </nav>

      <div className="mt-8">
        <SettingForm settingKey="hero" title="首页首屏" description="首页最重要的标题、副标题与两个行动按钮。" invalidReason={errors.hero} feedback={feedback?.key === 'hero' ? feedback : undefined}>
          <div className="grid gap-5 lg:grid-cols-2">
            {(['zh', 'en'] as const).map((locale) => {
              const value = initial.hero[locale];
              return <LocalePanel key={locale} locale={locale}>
                <TextField id={`${locale}-hero-title`} name={`${locale}_title`} label={locale === 'zh' ? '主标题' : 'Title'} maxLength={160} required={locale === 'zh'} value={value.title} />
                <TextField id={`${locale}-hero-subtitle`} name={`${locale}_subtitle`} label={locale === 'zh' ? '副标题' : 'Subtitle'} maxLength={500} value={value.subtitle} rows={3} />
                <div className="grid gap-3 sm:grid-cols-2">
                  <TextField id={`${locale}-hero-cta1`} name={`${locale}_cta1`} label={locale === 'zh' ? '按钮 1' : 'Button 1'} maxLength={120} value={value.cta1} />
                  <TextField id={`${locale}-hero-cta2`} name={`${locale}_cta2`} label={locale === 'zh' ? '按钮 2' : 'Button 2'} maxLength={120} value={value.cta2} />
                </div>
              </LocalePanel>;
            })}
          </div>
        </SettingForm>

        <SettingForm settingKey="capabilities" title="国际能力" description="维护制造、质量、OEM/ODM 与技术资料页的中英文核心表述；认证和测试不得脱离具体型号夸大。" invalidReason={errors.capabilities} feedback={feedback?.key === 'capabilities' ? feedback : undefined}>
          <div className="grid gap-5 lg:grid-cols-2">
            {(['zh', 'en'] as const).map((locale) => { const value = initial.capabilities[locale]; return <LocalePanel key={locale} locale={locale}>
              <TextField id={`${locale}-capabilities-title`} name={`${locale}_title`} label={locale === 'zh' ? '标题' : 'Title'} maxLength={180} required={locale === 'zh'} value={value.title} />
              <TextField id={`${locale}-capabilities-subtitle`} name={`${locale}_subtitle`} label={locale === 'zh' ? '副标题' : 'Subtitle'} maxLength={700} value={value.subtitle} rows={3} />
              <TextField id={`${locale}-capabilities-intro`} name={`${locale}_intro`} label={locale === 'zh' ? '能力总述' : 'Capability overview'} maxLength={3000} value={value.intro} rows={6} />
              <TextField id={`${locale}-capabilities-quality`} name={`${locale}_qualityBody`} label={locale === 'zh' ? '质量验证说明' : 'Quality verification'} maxLength={3000} value={value.qualityBody} rows={6} hint="只写有当前证据支持的范围；具体认证应绑定型号。" />
              <TextField id={`${locale}-capabilities-oem`} name={`${locale}_oemBody`} label={locale === 'zh' ? '制造与定制说明' : 'Manufacturing / OEM'} maxLength={3000} value={value.oemBody} rows={6} />
              <TextField id={`${locale}-capabilities-documents`} name={`${locale}_documentsBody`} label={locale === 'zh' ? '资料支持说明' : 'Document support'} maxLength={3000} value={value.documentsBody} rows={5} />
            </LocalePanel>; })}
          </div>
        </SettingForm>

        <SettingForm settingKey="partners" title="国际合作" description="维护国际渠道、工程与 OEM/ODM 合作页的主文案和流程补充。" invalidReason={errors.partners} feedback={feedback?.key === 'partners' ? feedback : undefined}>
          <div className="grid gap-5 lg:grid-cols-2">
            {(['zh', 'en'] as const).map((locale) => { const value = initial.partners[locale]; return <LocalePanel key={locale} locale={locale}>
              <TextField id={`${locale}-partners-title`} name={`${locale}_title`} label={locale === 'zh' ? '标题' : 'Title'} maxLength={180} required={locale === 'zh'} value={value.title} />
              <TextField id={`${locale}-partners-subtitle`} name={`${locale}_subtitle`} label={locale === 'zh' ? '副标题' : 'Subtitle'} maxLength={700} value={value.subtitle} rows={3} />
              <TextField id={`${locale}-partners-intro`} name={`${locale}_intro`} label={locale === 'zh' ? '合作说明' : 'Partnership overview'} maxLength={3000} value={value.intro} rows={6} />
              <TextField id={`${locale}-partners-process`} name={`${locale}_processBody`} label={locale === 'zh' ? '流程补充' : 'Process note'} maxLength={2000} value={value.processBody} rows={5} />
              <TextField id={`${locale}-partners-cta`} name={`${locale}_cta`} label={locale === 'zh' ? '按钮文字' : 'Button label'} maxLength={120} value={value.cta} />
            </LocalePanel>; })}
          </div>
        </SettingForm>

        <SettingForm settingKey="resources" title="专业资料" description="维护采购指南、文件申请和常见问题页的中英文核心说明。具体文章继续在“新闻资讯”中以采购指南分类维护。" invalidReason={errors.resources} feedback={feedback?.key === 'resources' ? feedback : undefined}>
          <div className="grid gap-5 lg:grid-cols-2">
            {(['zh', 'en'] as const).map((locale) => { const value = initial.resources[locale]; return <LocalePanel key={locale} locale={locale}>
              <TextField id={`${locale}-resources-title`} name={`${locale}_title`} label={locale === 'zh' ? '标题' : 'Title'} maxLength={180} required={locale === 'zh'} value={value.title} />
              <TextField id={`${locale}-resources-subtitle`} name={`${locale}_subtitle`} label={locale === 'zh' ? '副标题' : 'Subtitle'} maxLength={700} value={value.subtitle} rows={3} />
              <TextField id={`${locale}-resources-intro`} name={`${locale}_intro`} label={locale === 'zh' ? '资料页说明' : 'Resource overview'} maxLength={3000} value={value.intro} rows={6} />
              <TextField id={`${locale}-resources-documents`} name={`${locale}_documentsBody`} label={locale === 'zh' ? '文件申请说明' : 'Document request note'} maxLength={3000} value={value.documentsBody} rows={6} />
              <TextField id={`${locale}-resources-faq`} name={`${locale}_faqIntro`} label={locale === 'zh' ? '常见问题说明' : 'FAQ introduction'} maxLength={2000} value={value.faqIntro} rows={5} />
            </LocalePanel>; })}
          </div>
        </SettingForm>

        <SettingForm settingKey="about" title="关于我们" description="公司介绍、按钮和公开页面使用的三张企业图片。图片只接受站内路径。" invalidReason={errors.about} feedback={feedback?.key === 'about' ? feedback : undefined}>
          <div className="card-uten p-5">
            <div className="flex items-center gap-2"><ImageIcon className="h-4 w-4 text-accent" /><h3 className="font-semibold">企业图片</h3></div>
            <p className="mt-1 text-xs leading-relaxed text-muted-foreground">图片字段由中英文共用；保存时同步到本表单维护的两种语言，其他语言保持不变。</p>
            <div className="mt-4 grid gap-5 lg:grid-cols-3">
              {aboutImages.map((value, index) => <div key={index}><p className="label-uten">图片 {index + 1}</p><ImageUpload name={`image${index + 1}`} value={value} /></div>)}
            </div>
          </div>
          <div className="mt-5 grid gap-5 lg:grid-cols-2">
            {(['zh', 'en'] as const).map((locale) => {
              const value = initial.about[locale];
              return <LocalePanel key={locale} locale={locale}>
                <TextField id={`${locale}-about-title`} name={`${locale}_title`} label={locale === 'zh' ? '标题' : 'Title'} maxLength={160} required={locale === 'zh'} value={value.title} />
                <TextField id={`${locale}-about-subtitle`} name={`${locale}_subtitle`} label={locale === 'zh' ? '副标题' : 'Subtitle'} maxLength={240} value={value.subtitle} />
                <TextField id={`${locale}-about-body`} name={`${locale}_body`} label={locale === 'zh' ? '公司介绍' : 'Company introduction'} maxLength={5000} value={value.body} rows={8} />
                <TextField id={`${locale}-about-cta`} name={`${locale}_cta`} label={locale === 'zh' ? '按钮文字' : 'Button label'} maxLength={120} value={value.cta} />
              </LocalePanel>;
            })}
          </div>
        </SettingForm>

        <SettingForm settingKey="stats" title="企业数据" description="用于关于页面的数字和标签，可新增、删除并上下调整顺序。" invalidReason={errors.stats} feedback={feedback?.key === 'stats' ? feedback : undefined}>
          <div className="grid gap-5 lg:grid-cols-2">
            {(['zh', 'en'] as const).map((locale) => <StructuredListEditor key={locale} locale={locale} group="stats" title={locale === 'zh' ? '中文企业数据' : 'English company facts'} items={initial.stats[locale]} fields={[{ name: 'value', label: '数值', maxLength: 40, placeholder: '如 R&D / 2007' }, { name: 'label', label: '说明', maxLength: 120, placeholder: '如 研发制造 / 公司成立' }]} />)}
          </div>
        </SettingForm>

        <SettingForm settingKey="craft" title="核心工艺" description="维护工艺名称与说明，可新增、删除并上下调整顺序。" invalidReason={errors.craft} feedback={feedback?.key === 'craft' ? feedback : undefined}>
          <div className="grid gap-5 lg:grid-cols-2">
            {(['zh', 'en'] as const).map((locale) => <StructuredListEditor key={locale} locale={locale} group="craft" title={locale === 'zh' ? '中文工艺' : 'English craftsmanship'} items={initial.craft[locale]} fields={[{ name: 'title', label: '标题', maxLength: 160, placeholder: '工艺名称' }, { name: 'desc', label: '说明', maxLength: 500, placeholder: '已核实的工艺说明' }]} />)}
          </div>
        </SettingForm>

        <SettingForm settingKey="contact" title="联系方式" description="公司名称、电话、邮箱、地址与备案信息；服务端会校验电话和邮箱格式。" invalidReason={errors.contact} feedback={feedback?.key === 'contact' ? feedback : undefined}>
          <div className="grid gap-5 lg:grid-cols-2">
            {(['zh', 'en'] as const).map((locale) => {
              const value = initial.contact[locale];
              return <LocalePanel key={locale} locale={locale}>
                <TextField id={`${locale}-contact-company`} name={`${locale}_company`} label={locale === 'zh' ? '公司名称' : 'Company'} maxLength={200} value={value.company} />
                <div className="grid gap-3 sm:grid-cols-2">
                  <TextField id={`${locale}-contact-phone`} name={`${locale}_phone`} label={locale === 'zh' ? '电话' : 'Phone'} type="tel" maxLength={40} value={value.phone} />
                  <TextField id={`${locale}-contact-phone2`} name={`${locale}_phone2`} label={locale === 'zh' ? '备用电话' : 'Phone 2'} type="tel" maxLength={40} value={value.phone2} />
                </div>
                <TextField id={`${locale}-contact-email`} name={`${locale}_email`} label={locale === 'zh' ? '邮箱' : 'Email'} type="email" maxLength={160} value={value.email} />
                <TextField id={`${locale}-contact-address`} name={`${locale}_address`} label={locale === 'zh' ? '地址' : 'Address'} maxLength={500} value={value.address} rows={3} />
                <TextField id={`${locale}-contact-icp`} name={`${locale}_icp`} label={locale === 'zh' ? '备案号' : 'Registration / ICP'} maxLength={120} value={value.icp} />
              </LocalePanel>;
            })}
          </div>
        </SettingForm>

        <SettingForm settingKey="join" title="招商加盟" description="维护招商标题、说明、按钮和合作优势；优势支持增删排序。" invalidReason={errors.join} feedback={feedback?.key === 'join' ? feedback : undefined}>
          <div className="grid gap-5 lg:grid-cols-2">
            {(['zh', 'en'] as const).map((locale) => {
              const value = initial.join[locale];
              return <LocalePanel key={locale} locale={locale}>
                <TextField id={`${locale}-join-title`} name={`${locale}_title`} label={locale === 'zh' ? '标题' : 'Title'} maxLength={160} required={locale === 'zh'} value={value.title} />
                <TextField id={`${locale}-join-subtitle`} name={`${locale}_subtitle`} label={locale === 'zh' ? '副标题' : 'Subtitle'} maxLength={500} value={value.subtitle} rows={3} />
                <AdvantagesEditor locale={locale} items={Array.isArray(value.advantages) ? value.advantages : []} />
                <TextField id={`${locale}-join-cta`} name={`${locale}_cta`} label={locale === 'zh' ? '按钮文字' : 'Button label'} maxLength={120} value={value.cta} />
              </LocalePanel>;
            })}
          </div>
        </SettingForm>

        <SettingForm settingKey="careers" title="人才招聘" description="人才页的公司招聘主张和团队介绍；具体职位仍在“招聘职位”中维护。" invalidReason={errors.careers} feedback={feedback?.key === 'careers' ? feedback : undefined}>
          <div className="grid gap-5 lg:grid-cols-2">
            {(['zh', 'en'] as const).map((locale) => {
              const value = initial.careers[locale];
              return <LocalePanel key={locale} locale={locale}>
                <TextField id={`${locale}-careers-title`} name={`${locale}_title`} label={locale === 'zh' ? '标题' : 'Title'} maxLength={160} required={locale === 'zh'} value={value.title} />
                <TextField id={`${locale}-careers-subtitle`} name={`${locale}_subtitle`} label={locale === 'zh' ? '副标题' : 'Subtitle'} maxLength={500} value={value.subtitle} />
                <TextField id={`${locale}-careers-body`} name={`${locale}_body`} label={locale === 'zh' ? '团队介绍' : 'Team introduction'} maxLength={5000} value={value.body} rows={7} />
              </LocalePanel>;
            })}
          </div>
        </SettingForm>

        <SettingForm settingKey="footer" title="页脚" description="页脚公司简介和版权文字。" invalidReason={errors.footer} feedback={feedback?.key === 'footer' ? feedback : undefined}>
          <div className="grid gap-5 lg:grid-cols-2">
            {(['zh', 'en'] as const).map((locale) => {
              const value = initial.footer[locale];
              return <LocalePanel key={locale} locale={locale}>
                <TextField id={`${locale}-footer-about`} name={`${locale}_about`} label={locale === 'zh' ? '公司简介' : 'Company summary'} maxLength={1000} value={value.about} rows={5} />
                <TextField id={`${locale}-footer-copyright`} name={`${locale}_copyright`} label={locale === 'zh' ? '版权文字' : 'Copyright text'} maxLength={240} value={value.copyright} />
              </LocalePanel>;
            })}
          </div>
        </SettingForm>
      </div>
    </div>
  );
}
