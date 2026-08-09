'use client';

import { useRef, useState, type FormEvent } from 'react';
import Link from 'next/link';
import { Images, Plus, Trash2 } from 'lucide-react';
import { saveSeries } from '@/app/admin/actions';
import { pickLocale } from '@/lib/content';
import { ImageUpload } from './ImageUpload';
import { SERIES_CATALOG_ROLES } from '@/lib/product-taxonomy';

type SeriesMedia = {
  id: string;
  role: string;
  image: string;
  i18n: string;
  sortOrder: number;
  published: boolean;
};

type SeriesRecord = {
  id: string;
  code: string;
  publicSlug: string | null;
  catalogRole: string;
  rowVersion: number;
  i18n: string;
  coverImage: string | null;
  sortOrder: number;
  published: boolean;
  parentId: string | null;
  media: SeriesMedia[];
} | null;

type ParentOption = {
  id: string;
  code: string;
  name: string;
};

type SeriesLocale = {
  name?: string;
  subtitle?: string;
  description?: string;
};

type EditableMedia = SeriesMedia & { key: string; zhAlt: string; enAlt: string };

const SERIES_MEDIA_ROLES = ['hero', 'lineup', 'lifestyle', 'combination', 'detail'] as const;

const MEDIA_ROLE_LABELS: Record<string, string> = {
  combination: '系列组合封面（推荐）',
  hero: '头图 / Hero',
  lineup: '产品阵容 / Lineup',
  lifestyle: '生活方式 / Lifestyle',
  detail: '细节图 / Detail',
};

const ROLE_LABELS: Record<string, string> = {
  FAMILY: '产品家族 / FAMILY',
  COLLECTION: '产品集合 / COLLECTION',
  CONTAINER: '结构容器 / CONTAINER',
  ARCHIVE: '归档 / ARCHIVE',
  UNCLASSIFIED: '未分类 / UNCLASSIFIED',
};

function editableMedia(media: SeriesMedia): EditableMedia {
  return {
    ...media,
    key: media.id,
    zhAlt: pickLocale<{ alt?: string }>(media.i18n, 'zh')?.alt || '',
    enAlt: pickLocale<{ alt?: string }>(media.i18n, 'en')?.alt || '',
  };
}

function emptyMedia(key: string, sortOrder: number): EditableMedia {
  return {
    id: '',
    key,
    role: 'combination',
    image: '',
    i18n: '{}',
    zhAlt: '',
    enAlt: '',
    sortOrder,
    published: true,
  };
}

function mediaField(key: string, field: string) {
  return `seriesMedia_${key}_${field}`;
}

export function SeriesForm({
  series,
  parentOptions,
}: {
  series: SeriesRecord;
  parentOptions: ParentOption[];
}) {
  const zh = series ? (pickLocale<SeriesLocale>(series.i18n, 'zh') ?? {}) : {};
  const en = series ? (pickLocale<SeriesLocale>(series.i18n, 'en') ?? {}) : {};
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);
  const nextMediaKey = useRef(0);
  const [media, setMedia] = useState<EditableMedia[]>(() => (series?.media || []).map(editableMedia));

  const addMedia = () => {
    const key = `new-${nextMediaKey.current++}`;
    setMedia((current) => [...current, emptyMedia(key, current.length)]);
  };

  const onSubmit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setError('');
    setSaving(true);
    try {
      const result = await saveSeries(new FormData(event.currentTarget));
      if (result?.error) {
        setError(result.error);
        setSaving(false);
        window.scrollTo({ top: 0, behavior: 'smooth' });
      }
    } catch {
      setError('保存请求失败，请检查网络后重试');
      setSaving(false);
      window.scrollTo({ top: 0, behavior: 'smooth' });
    }
  };

  return (
    <form onSubmit={onSubmit} className="max-w-4xl pb-10">
      <div>
        <p className="text-xs font-semibold uppercase tracking-[0.18em] text-accent">Series CMS</p>
        <h1 className="mt-1 font-heading text-2xl font-bold">{series ? '编辑系列' : '新增系列'}</h1>
        <p className="mt-1 text-sm text-muted-foreground">维护系列层级、封面与各语言内容；空白英文不会自动复制中文。</p>
      </div>

      {error && (
        <div role="alert" aria-live="assertive" className="mt-4 rounded-lg bg-destructive/10 px-4 py-3 text-sm text-destructive">
          {error}
        </div>
      )}

      {series && (
        <>
          <input type="hidden" name="id" value={series.id} />
          <input type="hidden" name="rowVersion" value={series.rowVersion} />
        </>
      )}
      <section className="mt-5 card-uten space-y-5 p-5" aria-labelledby="series-base-heading">
        <div>
          <h2 id="series-base-heading" className="font-heading text-lg font-bold">基础资料</h2>
          <p className="mt-1 text-xs text-muted-foreground">网址代号保存后会用于公开链接；修改已有代号前请确认外部链接影响。</p>
        </div>
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <div>
            <label htmlFor="code" className="label-uten">网址代号 *</label>
            <input
              id="code"
              name="code"
              required
              maxLength={80}
              pattern="[a-z0-9]+(?:-[a-z0-9]+)*"
              title="仅允许小写字母、数字和连字符"
              defaultValue={series?.code || ''}
              className="input-uten font-mono"
              placeholder="如 z9、s300"
            />
          </div>
          <div>
            <label htmlFor="parentId" className="label-uten">上级系列</label>
            <select id="parentId" name="parentId" defaultValue={series?.parentId || ''} className="input-uten">
              <option value="">（顶级系列）</option>
              {parentOptions.map((option) => (
                <option key={option.id} value={option.id}>{option.name} · {option.code}</option>
              ))}
            </select>
          </div>
          <div>
            <label htmlFor="publicSlug" className="label-uten">公开聚合网址</label>
            <input
              id="publicSlug"
              name="publicSlug"
              maxLength={80}
              pattern="[a-z0-9]+(?:-[a-z0-9]+)*"
              defaultValue={series?.publicSlug || ''}
              className="input-uten font-mono"
              placeholder="如 s300、v4-white"
            />
            <p className="mt-1 text-xs text-muted-foreground">仅 FAMILY 导航聚合使用；未知时留空。</p>
          </div>
          <div>
            <label htmlFor="catalogRole" className="label-uten">目录角色</label>
            <select id="catalogRole" name="catalogRole" defaultValue={series?.catalogRole || 'UNCLASSIFIED'} className="input-uten">
              {SERIES_CATALOG_ROLES.map((role) => <option key={role} value={role}>{ROLE_LABELS[role] || role}</option>)}
            </select>
          </div>
          <div>
            <label htmlFor="sortOrder" className="label-uten">排序</label>
            <input id="sortOrder" name="sortOrder" type="number" min="0" step="1" defaultValue={series?.sortOrder ?? 0} className="input-uten tabular-nums" />
          </div>
        </div>
        <label className="flex min-h-11 cursor-pointer items-center gap-2 text-sm font-medium">
          <input type="checkbox" name="published" defaultChecked={series?.published ?? false} className="h-4 w-4 rounded border-border" />
          发布系列
        </label>
        <p className="text-xs leading-relaxed text-muted-foreground">CONTAINER 与 ARCHIVE 不能发布；FAMILY 仅作为已有公开产品的导航聚合。</p>
        <div>
          <p className="label-uten">系列封面</p>
          <ImageUpload name="coverImage" value={series?.coverImage || ''} />
          <p className="mt-2 text-xs text-muted-foreground">建议使用约 16:11 横图，并在同一画面展示多个代表产品；公开系列卡片会优先使用该封面。</p>
        </div>
      </section>

      <section className="mt-5 card-uten p-5" aria-labelledby="series-media-heading">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <div className="flex items-center gap-2">
              <Images className="h-5 w-5 text-accent" />
              <h2 id="series-media-heading" className="font-heading text-lg font-bold">系列展示素材</h2>
            </div>
            <p className="mt-1 max-w-2xl text-xs leading-relaxed text-muted-foreground">
              可维护头图、产品阵容、生活方式、组合封面与细节图；公开系列卡片会优先读取启用的 combination 素材。
            </p>
          </div>
          <button type="button" onClick={addMedia} className="btn-outline btn-sm min-h-11">
            <Plus className="h-4 w-4" />添加素材
          </button>
        </div>

        {media.length ? (
          <div className="mt-4 space-y-4">
            {media.map((item, index) => (
              <fieldset key={item.key} className="rounded-xl border border-border bg-background/60 p-4">
                <legend className="sr-only">系列素材 {index + 1}</legend>
                <input type="hidden" name="seriesMediaKey" value={item.key} />
                <input type="hidden" name={mediaField(item.key, 'id')} value={item.id} />
                <div className="flex items-start justify-between gap-3">
                  <p className="font-medium">素材 {index + 1}</p>
                  <button
                    type="button"
                    onClick={() => setMedia((current) => current.filter((candidate) => candidate.key !== item.key))}
                    className="flex min-h-11 items-center gap-2 rounded-lg px-3 text-sm text-destructive transition hover:bg-destructive/10"
                    aria-label={`移除系列素材 ${index + 1}`}
                  >
                    <Trash2 className="h-4 w-4" />移除
                  </button>
                </div>
                <div className="mt-3 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
                  <div>
                    <label htmlFor={`${item.key}-role`} className="label-uten">素材角色 *</label>
                    <select id={`${item.key}-role`} name={mediaField(item.key, 'role')} defaultValue={item.role} className="input-uten">
                      {SERIES_MEDIA_ROLES.map((role) => <option key={role} value={role}>{MEDIA_ROLE_LABELS[role] || role}</option>)}
                    </select>
                  </div>
                  <div>
                    <label htmlFor={`${item.key}-sort`} className="label-uten">排序</label>
                    <input id={`${item.key}-sort`} name={mediaField(item.key, 'sortOrder')} type="number" min="0" step="1" defaultValue={item.sortOrder} className="input-uten tabular-nums" />
                  </div>
                  <label className="flex min-h-11 cursor-pointer items-center gap-2 self-end text-sm font-medium">
                    <input type="checkbox" name={mediaField(item.key, 'published')} defaultChecked={item.published} className="h-4 w-4 rounded border-border" />
                    启用这张素材
                  </label>
                </div>
                <div className="mt-4">
                  <p className="label-uten">图片 *</p>
                  <ImageUpload name={mediaField(item.key, 'image')} value={item.image} />
                </div>
                <div className="mt-4 grid gap-4 sm:grid-cols-2">
                  <div>
                    <label htmlFor={`${item.key}-zh-alt`} className="label-uten">中文替代文字</label>
                    <input id={`${item.key}-zh-alt`} name={mediaField(item.key, 'zh_alt')} maxLength={240} defaultValue={item.zhAlt} className="input-uten" />
                  </div>
                  <div>
                    <label htmlFor={`${item.key}-en-alt`} className="label-uten">English alt text</label>
                    <input id={`${item.key}-en-alt`} name={mediaField(item.key, 'en_alt')} maxLength={240} defaultValue={item.enAlt} className="input-uten" />
                  </div>
                </div>
              </fieldset>
            ))}
          </div>
        ) : (
          <p className="mt-4 rounded-xl border border-dashed border-border px-4 py-5 text-center text-sm text-muted-foreground">
            暂无系列展示素材；旧封面仍会保留。
          </p>
        )}
      </section>

      <div className="mt-5 grid gap-5 lg:grid-cols-2">
        <fieldset className="card-uten space-y-4 border-l-4 border-l-accent p-5">
          <legend className="px-2 text-sm font-bold text-accent">中文</legend>
          <div>
            <label htmlFor="zh_name" className="label-uten">系列名称 *</label>
            <input id="zh_name" name="zh_name" required maxLength={160} defaultValue={zh.name || ''} className="input-uten" />
          </div>
          <div>
            <label htmlFor="zh_subtitle" className="label-uten">系列副标题</label>
            <input id="zh_subtitle" name="zh_subtitle" maxLength={240} defaultValue={zh.subtitle || ''} className="input-uten" />
          </div>
          <div>
            <label htmlFor="zh_desc" className="label-uten">系列描述</label>
            <textarea id="zh_desc" name="zh_desc" rows={5} maxLength={5000} defaultValue={zh.description || ''} className="input-uten resize-y" />
          </div>
        </fieldset>

        <fieldset className="card-uten space-y-4 border-l-4 border-l-accent p-5">
          <legend className="px-2 text-sm font-bold text-accent">English</legend>
          <div>
            <label htmlFor="en_name" className="label-uten">Series name</label>
            <input id="en_name" name="en_name" maxLength={160} defaultValue={en.name || ''} className="input-uten" />
          </div>
          <div>
            <label htmlFor="en_subtitle" className="label-uten">Subtitle</label>
            <input id="en_subtitle" name="en_subtitle" maxLength={240} defaultValue={en.subtitle || ''} className="input-uten" />
          </div>
          <div>
            <label htmlFor="en_desc" className="label-uten">Description</label>
            <textarea id="en_desc" name="en_desc" rows={5} maxLength={5000} defaultValue={en.description || ''} className="input-uten resize-y" />
          </div>
          <p className="text-xs leading-relaxed text-muted-foreground">全部留空会保持英文内容缺失，不会生成中文占位或伪翻译。</p>
        </fieldset>
      </div>

      <div className="mt-7 flex flex-wrap gap-3 border-t border-border pt-6">
        <button type="submit" disabled={saving} className="btn-accent min-h-11 disabled:cursor-wait disabled:opacity-60">
          {saving ? '保存中…' : '保存系列'}
        </button>
        <Link href="/admin/series" className="btn-outline min-h-11">取消</Link>
      </div>
    </form>
  );
}
