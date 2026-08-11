'use client';
import { useRef, useState, type FormEvent } from 'react';
import Link from 'next/link';
import { ClipboardList, Layers3, Plus, Trash2 } from 'lucide-react';
import { saveProduct } from '@/app/admin/actions';
import { ImageUpload } from './ImageUpload';
import { pickLocale } from '@/lib/content';
import {
  readAdminProductSpecs,
  type ProductSpecItem,
} from '@/lib/admin-i18n';
import {
  PRODUCT_CLASSIFICATION_STATUSES,
  PRODUCT_FUNCTION_TYPES,
} from '@/lib/product-taxonomy';

type SeriesLite = { id: string; code: string; name: string; published: boolean; catalogRole: string };

type ProductVariant = {
  id: string;
  sku: string | null;
  i18n: string;
  swatchHex: string | null;
  image: string | null;
  gallery: string | null;
  finish: string | null;
  widthMm: number | null;
  heightMm: number | null;
  depthMm: number | null;
  legacySynthetic: boolean;
  dataStatus: string;
  isDefault: boolean;
  published: boolean;
  sortOrder: number;
};

type Product = {
  id: string;
  model: string | null;
  category: string | null;
  functionType: string | null;
  gangCount: number | null;
  controlMode: string | null;
  configuration: string | null;
  classificationStatus: string;
  rowVersion: number;
  image: string | null;
  minOrderQty: number | null;
  sceneEnabled: boolean;
  featured: boolean;
  published: boolean;
  sortOrder: number;
  series: { code: string } | null;
  variants: ProductVariant[];
  i18n: string | null;
  specs: string | null;
} | null;

type EditableVariant = ProductVariant & {
  key: string;
  zhName: string;
  enName: string;
  galleryText: string;
};

type EditableSpec = ProductSpecItem & { key: string };

const FUNCTION_LABELS: Record<string, string> = {
  switches: '开关',
  'power-sockets': '电源插座',
  'usb-charging': 'USB / Type-C 充电',
  'data-media': '数据 / 影音',
  'smart-controls': '智能 / 调光 / 感应控制',
  hospitality: '酒店控制',
  accessories: '附件 / 面板',
  other: '其他',
};

const STATUS_LABELS: Record<string, string> = {
  VERIFIED: '已人工核实',
  INFERRED: '系统推断，待复核',
  NEEDS_REVIEW: '需要复核',
};

const CONTROL_MODE_OPTIONS = [
  ['ONE_WAY', '单控 / One-way'],
  ['TWO_WAY', '双控 / Two-way'],
  ['MULTIWAY', '多控 / Multi-way'],
  ['INTERMEDIATE', '中途 / Intermediate'],
] as const;

function galleryToText(value: string | null): string {
  if (!value) return '';
  try {
    const parsed = JSON.parse(value) as unknown;
    return Array.isArray(parsed) ? parsed.filter((item) => typeof item === 'string').join('\n') : '';
  } catch {
    return value;
  }
}

function existingVariant(variant: ProductVariant): EditableVariant {
  const zh = pickLocale<{ name?: string }>(variant.i18n, 'zh') ?? {};
  const en = pickLocale<{ name?: string }>(variant.i18n, 'en') ?? {};
  return {
    ...variant,
    key: variant.id,
    zhName: zh.name || '',
    enName: en.name || '',
    galleryText: galleryToText(variant.gallery),
  };
}

function emptyVariant(key: string, name = '', isDefault = false): EditableVariant {
  return {
    key,
    id: '',
    sku: null,
    i18n: '',
    swatchHex: null,
    image: null,
    gallery: null,
    finish: null,
    widthMm: null,
    heightMm: null,
    depthMm: null,
    legacySynthetic: false,
    dataStatus: 'NEEDS_REVIEW',
    isDefault,
    published: true,
    sortOrder: 0,
    zhName: name,
    enName: '',
    galleryText: '',
  };
}

function variantField(key: string, field: string) {
  return `variant_${key}_${field}`;
}

function productSpecsForLocale(value: string | null | undefined, locale: 'zh' | 'en') {
  try {
    return { items: readAdminProductSpecs(value, locale), error: '' };
  } catch (error) {
    return {
      items: [],
      error: error instanceof Error ? error.message : '现有规格数据格式异常',
    };
  }
}

function SpecsEditor({
  locale,
  title,
  items,
}: {
  locale: 'zh' | 'en';
  title: string;
  items: ProductSpecItem[];
}) {
  const nextKey = useRef(items.length);
  const [specs, setSpecs] = useState<EditableSpec[]>(() => items.map((item, index) => ({
    ...item,
    key: `${locale}-existing-${index}`,
  })));

  const addSpec = () => {
    const key = `${locale}-new-${nextKey.current++}`;
    setSpecs((current) => [...current, { key, label: '', value: '' }]);
  };

  return (
    <fieldset className="card-uten p-5">
      <legend className="px-2 text-sm font-bold text-accent">{title}</legend>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <p className="max-w-md text-xs leading-relaxed text-muted-foreground">
          {locale === 'zh'
            ? '逐项填写参数名称和值；没有可靠资料时请留空，不要推测。'
            : 'Only enter verified English specifications. Empty English data remains missing.'}
        </p>
        <button type="button" onClick={addSpec} className="btn-outline btn-sm min-h-11">
          <Plus className="h-4 w-4" />{locale === 'zh' ? '添加规格' : 'Add specification'}
        </button>
      </div>

      {specs.length ? (
        <div className="mt-4 space-y-3">
          {specs.map((spec, index) => (
            <fieldset key={spec.key} className="rounded-xl border border-border bg-background/60 p-3">
              <legend className="sr-only">{title} {locale === 'zh' ? `规格 ${index + 1}` : `specification ${index + 1}`}</legend>
              <div className="grid gap-3 sm:grid-cols-[minmax(0,.8fr)_minmax(0,1.2fr)_auto] sm:items-end">
                <div>
                  <label htmlFor={`${spec.key}-label`} className="label-uten">
                    {locale === 'zh' ? '参数名称' : 'Label'} *
                  </label>
                  <input
                    id={`${spec.key}-label`}
                    name={`spec_${locale}_label`}
                    required
                    maxLength={120}
                    defaultValue={spec.label}
                    className="input-uten"
                    placeholder={locale === 'zh' ? '如 额定电流' : 'e.g. Rated current'}
                  />
                </div>
                <div>
                  <label htmlFor={`${spec.key}-value`} className="label-uten">
                    {locale === 'zh' ? '参数值' : 'Value'} *
                  </label>
                  <input
                    id={`${spec.key}-value`}
                    name={`spec_${locale}_value`}
                    required
                    maxLength={500}
                    defaultValue={spec.value}
                    className="input-uten"
                    placeholder={locale === 'zh' ? '如 10 A / 250 V~' : 'e.g. 10 A / 250 V~'}
                  />
                </div>
                <button
                  type="button"
                  onClick={() => setSpecs((current) => current.filter((item) => item.key !== spec.key))}
                  className="flex min-h-11 items-center justify-center gap-2 rounded-lg px-3 text-sm text-destructive transition hover:bg-destructive/10"
                  aria-label={locale === 'zh' ? `移除规格 ${index + 1}` : `Remove specification ${index + 1}`}
                >
                  <Trash2 className="h-4 w-4" />
                  <span className="sm:sr-only">{locale === 'zh' ? '移除' : 'Remove'}</span>
                </button>
              </div>
            </fieldset>
          ))}
        </div>
      ) : (
        <p className="mt-4 rounded-xl border border-dashed border-border px-4 py-5 text-center text-sm text-muted-foreground">
          {locale === 'zh' ? '暂未填写规格' : 'No English specifications'}
        </p>
      )}
    </fieldset>
  );
}

function SwatchField({ fieldName, value }: { fieldName: string; value: string | null }) {
  const [swatch, setSwatch] = useState(value || '');
  const colorValue = /^#[0-9a-fA-F]{6}$/.test(swatch) ? swatch : '#d6d3d1';
  return (
    <div className="flex items-center gap-2">
      <input
        type="color"
        value={colorValue}
        onChange={(event) => setSwatch(event.target.value)}
        className="h-11 w-12 cursor-pointer rounded-lg border border-border bg-card p-1"
        aria-label="选择色卡颜色"
      />
      <input
        name={fieldName}
        value={swatch}
        onChange={(event) => setSwatch(event.target.value)}
        className="input-uten font-mono"
        placeholder="#C8B08A（可选）"
        pattern="#[0-9a-fA-F]{3}|#[0-9a-fA-F]{6}"
      />
    </div>
  );
}

export function ProductForm({ product, series }: { product: Product; series: SeriesLite[] }) {
  const zh = product
    ? (pickLocale<{ name?: string; description?: string }>(product.i18n, 'zh') ?? {})
    : {};
  const en = product
    ? (pickLocale<{ name?: string; description?: string }>(product.i18n, 'en') ?? {})
    : {};
  const zhSpecs = productSpecsForLocale(product?.specs, 'zh');
  const enSpecs = productSpecsForLocale(product?.specs, 'en');
  const specsError = zhSpecs.error || enSpecs.error;
  const nextVariantKey = useRef(1);
  const [variants, setVariants] = useState<EditableVariant[]>(() => {
    if (product?.variants.length) return product.variants.map(existingVariant);
    return [emptyVariant('new-0', '标准款', true)];
  });
  const [err, setErr] = useState('');
  const [saving, setSaving] = useState(false);

  const addVariant = () => {
    const key = `new-${nextVariantKey.current++}`;
    setVariants((current) => [...current, { ...emptyVariant(key), sortOrder: current.length }]);
  };

  const removeVariant = (key: string) => {
    if (variants.length <= 1) return;
    setVariants((current) => current.filter((variant) => variant.key !== key));
  };

  const onSubmit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setErr('');
    setSaving(true);
    try {
      const result = await saveProduct(new FormData(event.currentTarget));
      if (result?.error) {
        setErr(result.error);
        setSaving(false);
        window.scrollTo({ top: 0, behavior: 'smooth' });
      }
    } catch {
      setErr('保存请求失败，请检查网络后重试');
      setSaving(false);
      window.scrollTo({ top: 0, behavior: 'smooth' });
    }
  };

  return (
    <form onSubmit={onSubmit} className="max-w-5xl pb-10">
      <div>
        <p className="text-xs font-semibold uppercase tracking-[0.18em] text-accent">Product CMS</p>
        <h1 className="mt-1 font-heading text-2xl font-bold">{product ? '编辑产品' : '新增产品'}</h1>
        <p className="mt-1 text-sm text-muted-foreground">维护产品基础资料，以及用于展示和场景试装的具体颜色 / 材质款式。</p>
      </div>
      {err && (
        <div role="alert" aria-live="assertive" className="mt-4 rounded-lg bg-destructive/10 px-4 py-3 text-sm text-destructive">
          {err}
        </div>
      )}

      <section className="mt-5 card-uten space-y-5 p-5" aria-labelledby="product-base-heading">
        <div>
          <h2 id="product-base-heading" className="font-heading text-lg font-bold">基础资料</h2>
          <p className="mt-1 text-xs text-muted-foreground">型号和分类用于检索与展示；未知信息可留空。</p>
        </div>
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <div>
            <label htmlFor="seriesCode" className="label-uten">所属系列</label>
            <select id="seriesCode" name="seriesCode" defaultValue={product?.series?.code || ''} className="input-uten">
              <option value="">(无系列)</option>
              {series.map((item) => (
                <option key={item.id} value={item.code}>
                  {item.name} · {item.catalogRole}{item.published ? '' : '（未发布）'}
                </option>
              ))}
            </select>
            <p className="mt-1 text-xs text-muted-foreground">发布产品必须选择已发布系列。</p>
          </div>
          <div>
            <label htmlFor="model" className="label-uten">产品型号</label>
            <input id="model" name="model" defaultValue={product?.model || ''} className="input-uten" placeholder="如 GK11" />
          </div>
          <div>
            <label htmlFor="category" className="label-uten">产品分类</label>
            <input id="category" name="category" defaultValue={product?.category || ''} className="input-uten" placeholder="如 墙壁开关" />
            <p className="mt-1 text-xs text-muted-foreground">旧导入来源字段，仅兼容保留；新分类请使用下方受控字段。</p>
          </div>
          <div>
            <label htmlFor="functionType" className="label-uten">功能类型</label>
            <select id="functionType" name="functionType" defaultValue={product?.functionType || ''} className="input-uten">
              <option value="">未知 / 暂不分类</option>
              {PRODUCT_FUNCTION_TYPES.map((value) => (
                <option key={value} value={value}>{FUNCTION_LABELS[value] || value}</option>
              ))}
            </select>
          </div>
          <div>
            <label htmlFor="gangCount" className="label-uten">联数 / 位数</label>
            <input id="gangCount" name="gangCount" type="number" min="1" max="12" step="1" defaultValue={product?.gangCount ?? ''} className="input-uten tabular-nums" placeholder="未知可留空" />
          </div>
          <div>
            <label htmlFor="controlMode" className="label-uten">控制方式</label>
            <select id="controlMode" name="controlMode" defaultValue={product?.controlMode || ''} className="input-uten">
              <option value="">不适用 / 未知</option>
              {CONTROL_MODE_OPTIONS.map(([value, label]) => <option key={value} value={value}>{label}</option>)}
            </select>
          </div>
          <div>
            <label htmlFor="classificationStatus" className="label-uten">分类审核状态</label>
            <select id="classificationStatus" name="classificationStatus" defaultValue={product?.classificationStatus || 'NEEDS_REVIEW'} className="input-uten">
              {PRODUCT_CLASSIFICATION_STATUSES.map((value) => (
                <option key={value} value={value}>{STATUS_LABELS[value] || value}</option>
              ))}
            </select>
          </div>
          <div>
            <label htmlFor="minOrderQty" className="label-uten">最小起订量</label>
            <input id="minOrderQty" name="minOrderQty" type="number" min="1" step="1" defaultValue={product?.minOrderQty ?? ''} className="input-uten tabular-nums" placeholder="未知可留空" />
          </div>
          <div>
            <label htmlFor="sortOrder" className="label-uten">排序</label>
            <input id="sortOrder" name="sortOrder" type="number" min="0" step="1" defaultValue={product?.sortOrder ?? 0} className="input-uten tabular-nums" />
          </div>
        </div>
        <div>
          <label htmlFor="configuration" className="label-uten">配置说明</label>
          <textarea
            id="configuration"
            name="configuration"
            rows={3}
            maxLength={1000}
            defaultValue={product?.configuration || ''}
            className="input-uten resize-y"
            placeholder="仅填写已确认的结构、模块或控制配置；未知时留空。"
          />
        </div>
        <div>
          <p className="label-uten">产品列表主图</p>
          <ImageUpload name="image" value={product?.image || ''} />
          <p className="mt-2 text-xs text-muted-foreground">用于产品列表兼容展示；场景试装会优先使用下方具体款式的正面图。</p>
        </div>
        <div className="flex flex-wrap gap-x-6 gap-y-3">
          <label className="flex min-h-11 cursor-pointer items-center gap-2 text-sm font-medium">
            <input type="checkbox" name="published" defaultChecked={product?.published ?? false} className="h-4 w-4 rounded border-border" />
            发布产品
          </label>
          <label className="flex min-h-11 cursor-pointer items-center gap-2 text-sm font-medium">
            <input type="checkbox" name="featured" defaultChecked={product?.featured} className="h-4 w-4 rounded border-border" />
            设为首页最新 / 主推产品
          </label>
          <label className="flex min-h-11 cursor-pointer items-center gap-2 text-sm font-medium">
            <input type="checkbox" name="sceneEnabled" defaultChecked={product?.sceneEnabled} className="h-4 w-4 rounded border-border" />
            允许场景试装
          </label>
        </div>
      </section>

      <div className="mt-5 grid gap-5 lg:grid-cols-2">
        <fieldset className="card-uten space-y-3 border-l-4 border-l-accent p-5">
          <legend className="px-2 text-sm font-bold text-accent">中文</legend>
          <div>
            <label htmlFor="zh_name" className="label-uten">产品名称 *</label>
            <input id="zh_name" name="zh_name" required defaultValue={zh.name || ''} className="input-uten" />
          </div>
          <div>
            <label htmlFor="zh_desc" className="label-uten">产品描述</label>
            <textarea id="zh_desc" name="zh_desc" rows={5} defaultValue={zh.description || ''} className="input-uten resize-y" />
          </div>
        </fieldset>

        <fieldset className="card-uten space-y-3 border-l-4 border-l-accent p-5">
          <legend className="px-2 text-sm font-bold text-accent">English</legend>
          <div>
            <label htmlFor="en_name" className="label-uten">Product Name</label>
            <input id="en_name" name="en_name" defaultValue={en.name || ''} className="input-uten" />
          </div>
          <div>
            <label htmlFor="en_desc" className="label-uten">Description</label>
            <textarea id="en_desc" name="en_desc" rows={5} defaultValue={en.description || ''} className="input-uten resize-y" />
          </div>
          <p className="text-xs text-muted-foreground">英文留空会保持为“缺失”，不会把中文写成伪翻译；前台仍可按展示回退规则显示中文。</p>
        </fieldset>
      </div>

      <section className="mt-7" aria-labelledby="product-specs-heading">
        <div className="flex items-center gap-2">
          <ClipboardList className="h-5 w-5 text-accent" />
          <h2 id="product-specs-heading" className="font-heading text-xl font-bold">技术规格</h2>
        </div>
        <p className="mt-1 text-sm text-muted-foreground">中文与英文规格分开维护；保存时不会删除法语、德语等未显示语言的数据。</p>
        {specsError && (
          <div role="alert" className="mt-4 rounded-lg bg-destructive/10 px-4 py-3 text-sm text-destructive">
            现有规格无法安全读取：{specsError}。请先核对原始 JSON；本次保存不会静默覆盖该数据。
          </div>
        )}
        <div className="mt-4 grid gap-5 lg:grid-cols-2">
          <SpecsEditor locale="zh" title="中文规格" items={zhSpecs.items} />
          <SpecsEditor locale="en" title="English specifications" items={enSpecs.items} />
        </div>
      </section>

      <section className="mt-7" aria-labelledby="variant-heading">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <div className="flex items-center gap-2">
              <Layers3 className="h-5 w-5 text-accent" />
              <h2 id="variant-heading" className="font-heading text-xl font-bold">颜色 / 材质款式</h2>
            </div>
            <p className="mt-1 text-sm text-muted-foreground">每个款式拥有独立图片、表面工艺与尺寸；场景试装会让访客选择到具体款式。</p>
          </div>
          <button type="button" onClick={addVariant} className="btn-outline btn-sm min-h-11">
            <Plus className="h-4 w-4" />新增款式
          </button>
        </div>

        <div className="mt-4 space-y-5">
          {variants.map((variant, index) => {
            const prefix = variant.key;
            return (
              <fieldset key={variant.key} className="card-uten p-5">
                <legend className="sr-only">款式 {index + 1}</legend>
                <input type="hidden" name="variantKey" value={variant.key} />
                <input type="hidden" name={variantField(prefix, 'id')} value={variant.id} />
                <div className="flex items-start justify-between gap-4 border-b border-border pb-4">
                  <div>
                    <p className="font-heading font-bold">款式 {index + 1}</p>
                    <p className="mt-1 text-xs text-muted-foreground">已保存款式只有在提交产品后才会真正删除或更新。</p>
                  </div>
                  <button
                    type="button"
                    onClick={() => removeVariant(variant.key)}
                    disabled={variants.length <= 1}
                    className="flex min-h-11 items-center gap-2 rounded-lg px-3 text-sm text-destructive transition hover:bg-destructive/10 disabled:cursor-not-allowed disabled:opacity-40"
                    title={variants.length <= 1 ? '产品至少保留一个款式' : '移除这个款式'}
                  >
                    <Trash2 className="h-4 w-4" />移除
                  </button>
                </div>

                <div className="mt-5 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
                  <div>
                    <label htmlFor={`${prefix}-zh-name`} className="label-uten">中文款式名 *</label>
                    <input id={`${prefix}-zh-name`} name={variantField(prefix, 'zh_name')} required defaultValue={variant.zhName} className="input-uten" placeholder="如 标准款 / 香槟金" />
                  </div>
                  <div>
                    <label htmlFor={`${prefix}-en-name`} className="label-uten">English name</label>
                    <input id={`${prefix}-en-name`} name={variantField(prefix, 'en_name')} defaultValue={variant.enName} className="input-uten" placeholder="Standard" />
                  </div>
                  <div>
                    <label htmlFor={`${prefix}-sku`} className="label-uten">SKU / 内部编码</label>
                    <input id={`${prefix}-sku`} name={variantField(prefix, 'sku')} defaultValue={variant.sku || ''} className="input-uten" />
                    <p className="mt-1 text-xs text-muted-foreground">旧站合成占位款式必须留空。</p>
                  </div>
                  <div>
                    <label htmlFor={`${prefix}-finish`} className="label-uten">表面工艺</label>
                    <input id={`${prefix}-finish`} name={variantField(prefix, 'finish')} defaultValue={variant.finish || ''} className="input-uten" placeholder="如 拉丝 / 钢化玻璃" />
                  </div>
                  <div>
                    <span className="label-uten">色卡（可选）</span>
                    <SwatchField fieldName={variantField(prefix, 'swatchHex')} value={variant.swatchHex} />
                  </div>
                  <div>
                    <label htmlFor={`${prefix}-sort`} className="label-uten">排序</label>
                    <input id={`${prefix}-sort`} name={variantField(prefix, 'sortOrder')} type="number" min="0" step="1" defaultValue={variant.sortOrder} className="input-uten tabular-nums" />
                  </div>
                  <div>
                    <label htmlFor={`${prefix}-data-status`} className="label-uten">数据状态</label>
                    <select
                      id={`${prefix}-data-status`}
                      name={variantField(prefix, 'dataStatus')}
                      defaultValue={variant.dataStatus || 'NEEDS_REVIEW'}
                      className="input-uten"
                    >
                      {PRODUCT_CLASSIFICATION_STATUSES.map((value) => (
                        <option key={value} value={value}>{STATUS_LABELS[value] || value}</option>
                      ))}
                    </select>
                  </div>
                </div>

                <div className="mt-5">
                  <p className="label-uten">款式正面图</p>
                  <ImageUpload name={variantField(prefix, 'image')} value={variant.image || ''} />
                  <p className="mt-2 text-xs text-muted-foreground">用于场景试装时建议使用正视角、背景干净或透明底的产品图。</p>
                </div>

                <div className="mt-5 grid gap-4 lg:grid-cols-[1.25fr_1fr]">
                  <div>
                    <label htmlFor={`${prefix}-gallery`} className="label-uten">款式图集</label>
                    <textarea
                      id={`${prefix}-gallery`}
                      name={variantField(prefix, 'gallery')}
                      rows={4}
                      defaultValue={variant.galleryText}
                      className="input-uten resize-y font-mono text-xs"
                      placeholder={'每行一个图片路径\n/images/raw/example.jpg'}
                    />
                    <p className="mt-1 text-xs text-muted-foreground">提交后保存为 JSON 图片数组，无需手写 JSON。</p>
                  </div>
                  <div>
                    <p className="label-uten">外形尺寸（mm）</p>
                    <div className="grid grid-cols-3 gap-2">
                      <div>
                        <label htmlFor={`${prefix}-width`} className="text-xs text-muted-foreground">宽</label>
                        <input id={`${prefix}-width`} name={variantField(prefix, 'widthMm')} type="number" min="0.1" step="0.1" defaultValue={variant.widthMm ?? ''} className="input-uten mt-1 tabular-nums" />
                      </div>
                      <div>
                        <label htmlFor={`${prefix}-height`} className="text-xs text-muted-foreground">高</label>
                        <input id={`${prefix}-height`} name={variantField(prefix, 'heightMm')} type="number" min="0.1" step="0.1" defaultValue={variant.heightMm ?? ''} className="input-uten mt-1 tabular-nums" />
                      </div>
                      <div>
                        <label htmlFor={`${prefix}-depth`} className="text-xs text-muted-foreground">厚</label>
                        <input id={`${prefix}-depth`} name={variantField(prefix, 'depthMm')} type="number" min="0.1" step="0.1" defaultValue={variant.depthMm ?? ''} className="input-uten mt-1 tabular-nums" />
                      </div>
                    </div>
                    <div className="mt-4 space-y-2 rounded-xl border border-border bg-background/60 p-3">
                      <label className="flex min-h-11 cursor-pointer items-center gap-2 text-sm font-medium">
                        <input type="radio" name="defaultVariantKey" value={prefix} defaultChecked={variant.isDefault} className="h-4 w-4 border-border" />
                        设为默认款式
                      </label>
                      <label className="flex min-h-11 cursor-pointer items-center gap-2 text-sm font-medium">
                        <input type="checkbox" name={variantField(prefix, 'legacySynthetic')} defaultChecked={variant.legacySynthetic} className="h-4 w-4 rounded border-border" />
                        旧站合成占位款式
                      </label>
                      <label className="flex min-h-11 cursor-pointer items-center gap-2 text-sm font-medium">
                        <input type="checkbox" name={variantField(prefix, 'published')} defaultChecked={variant.published} className="h-4 w-4 rounded border-border" />
                        发布这个款式
                      </label>
                      <p className="text-xs leading-relaxed text-muted-foreground">
                        合成占位款式可继续展示，但不能填写 SKU，也不能标为“已人工核实”。
                      </p>
                    </div>
                  </div>
                </div>
              </fieldset>
            );
          })}
        </div>
      </section>

      {product && (
        <>
          <input type="hidden" name="id" value={product.id} />
          <input type="hidden" name="rowVersion" value={product.rowVersion} />
        </>
      )}
      <div className="mt-7 flex flex-wrap gap-3 border-t border-border pt-6">
        <button type="submit" disabled={saving} className="btn-accent min-h-11 disabled:cursor-wait disabled:opacity-60">
          {saving ? '保存中…' : '保存产品'}
        </button>
        <Link href="/admin/products" className="btn-outline min-h-11">取消</Link>
      </div>
    </form>
  );
}
