'use client';
import { useState, type FormEvent } from 'react';
import Link from 'next/link';
import { saveScenePreset } from '@/app/admin/actions';
import { ImageUpload } from '@/components/admin/ImageUpload';
import { pickLocale } from '@/lib/content';

export type ScenePlacement = { x: number; y: number; scale: number; rotation: number };

type Scene = {
  id: string;
  slug: string;
  i18n: string;
  backgroundImage: string;
  published: boolean;
  sortOrder: number;
} | null;

type VariantOption = { id: string; label: string; image: string };

export function SceneForm({
  scene,
  variants,
  config,
}: {
  scene: Scene;
  variants: VariantOption[];
  config: { defaultVariantId: string; placement: ScenePlacement };
}) {
  const zh = scene ? (pickLocale<{ name?: string; description?: string }>(scene.i18n, 'zh') ?? {}) : {};
  const en = scene ? (pickLocale<{ name?: string; description?: string }>(scene.i18n, 'en') ?? {}) : {};
  const [err, setErr] = useState('');
  const [saving, setSaving] = useState(false);

  const onSubmit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setErr('');
    setSaving(true);
    try {
      const result = await saveScenePreset(new FormData(event.currentTarget));
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
    <form onSubmit={onSubmit} className="max-w-4xl pb-10">
      <div>
        <p className="text-xs font-semibold uppercase tracking-[0.18em] text-accent">Scene preset</p>
        <h1 className="mt-1 font-heading text-2xl font-bold">{scene ? '编辑场景' : '新增场景'}</h1>
        <p className="mt-1 text-sm text-muted-foreground">背景与安装参数会直接提供给前台试装工具，访客仍可切换其他具体产品款式。</p>
      </div>
      {err && (
        <div role="alert" aria-live="assertive" className="mt-4 rounded-lg bg-destructive/10 px-4 py-3 text-sm text-destructive">
          {err}
        </div>
      )}

      {scene && <input type="hidden" name="id" value={scene.id} />}
      <section className="mt-5 card-uten space-y-5 p-5" aria-labelledby="scene-base-heading">
        <div>
          <h2 id="scene-base-heading" className="font-heading text-lg font-bold">场景设置</h2>
          <p className="mt-1 text-xs text-muted-foreground">网址标识发布后尽量不要修改，以免旧链接失效。</p>
        </div>
        <div className="grid gap-4 sm:grid-cols-2">
          <div>
            <label htmlFor="slug" className="label-uten">网址标识 *</label>
            <input id="slug" name="slug" required pattern="[a-z0-9]+(?:-[a-z0-9]+)*" defaultValue={scene?.slug || ''} className="input-uten font-mono" placeholder="warm-plaster" />
          </div>
          <div>
            <label htmlFor="sortOrder" className="label-uten">排序</label>
            <input id="sortOrder" name="sortOrder" type="number" min="0" step="1" defaultValue={scene?.sortOrder ?? 0} className="input-uten tabular-nums" />
          </div>
        </div>
        <div>
          <p className="label-uten">场景背景图 *</p>
          <ImageUpload name="backgroundImage" value={scene?.backgroundImage || ''} />
          <p className="mt-2 text-xs text-muted-foreground">建议使用横向 WebP 图片并保留足够留白，避免产品遮挡空间主体。</p>
        </div>
        <label className="flex min-h-11 cursor-pointer items-center gap-2 text-sm font-medium">
          <input type="checkbox" name="published" defaultChecked={scene?.published ?? true} className="h-4 w-4 rounded border-border" />
          发布这个场景
        </label>
      </section>

      <div className="mt-5 grid gap-5 lg:grid-cols-2">
        <fieldset className="card-uten space-y-3 border-l-4 border-l-accent p-5">
          <legend className="px-2 text-sm font-bold text-accent">中文</legend>
          <div>
            <label htmlFor="zh_name" className="label-uten">场景名称 *</label>
            <input id="zh_name" name="zh_name" required defaultValue={zh.name || ''} className="input-uten" />
          </div>
          <div>
            <label htmlFor="zh_description" className="label-uten">场景说明</label>
            <textarea id="zh_description" name="zh_description" rows={4} defaultValue={zh.description || ''} className="input-uten resize-y" />
          </div>
        </fieldset>
        <fieldset className="card-uten space-y-3 border-l-4 border-l-accent p-5">
          <legend className="px-2 text-sm font-bold text-accent">English</legend>
          <div>
            <label htmlFor="en_name" className="label-uten">Scene name</label>
            <input id="en_name" name="en_name" defaultValue={en.name || ''} className="input-uten" />
          </div>
          <div>
            <label htmlFor="en_description" className="label-uten">Description</label>
            <textarea id="en_description" name="en_description" rows={4} defaultValue={en.description || ''} className="input-uten resize-y" />
          </div>
          <p className="text-xs text-muted-foreground">英文留空会保持为“缺失”，不会把中文写成伪翻译；前台仍可按展示回退规则显示中文。</p>
        </fieldset>
      </div>

      <section className="mt-5 card-uten space-y-5 p-5" aria-labelledby="placement-heading">
        <div>
          <h2 id="placement-heading" className="font-heading text-lg font-bold">默认试装效果</h2>
          <p className="mt-1 text-xs text-muted-foreground">选择具体款式，并设定它首次出现在背景中的位置。前台访客可以继续拖动、缩放和更换款式。</p>
        </div>
        <div>
          <label htmlFor="defaultVariantId" className="label-uten">默认产品款式</label>
          <select id="defaultVariantId" name="defaultVariantId" defaultValue={config.defaultVariantId} className="input-uten">
            <option value="">不预选款式</option>
            {variants.map((variant) => <option key={variant.id} value={variant.id}>{variant.label}</option>)}
          </select>
          {!variants.length && <p className="mt-2 text-xs text-destructive">暂无可试装款式。请先在产品中启用“允许场景试装”，并上传款式正面图。</p>}
        </div>
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <div>
            <label htmlFor="positionX" className="label-uten">水平位置（%）</label>
            <input id="positionX" name="positionX" type="number" min="0" max="100" step="0.1" defaultValue={config.placement.x} className="input-uten tabular-nums" />
          </div>
          <div>
            <label htmlFor="positionY" className="label-uten">垂直位置（%）</label>
            <input id="positionY" name="positionY" type="number" min="0" max="100" step="0.1" defaultValue={config.placement.y} className="input-uten tabular-nums" />
          </div>
          <div>
            <label htmlFor="scale" className="label-uten">初始缩放</label>
            <input id="scale" name="scale" type="number" min="0.1" max="4" step="0.05" defaultValue={config.placement.scale} className="input-uten tabular-nums" />
          </div>
          <div>
            <label htmlFor="rotation" className="label-uten">旋转角度（°）</label>
            <input id="rotation" name="rotation" type="number" min="-180" max="180" step="0.1" defaultValue={config.placement.rotation} className="input-uten tabular-nums" />
          </div>
        </div>
      </section>

      <div className="mt-7 flex flex-wrap gap-3 border-t border-border pt-6">
        <button type="submit" disabled={saving} className="btn-accent min-h-11 disabled:cursor-wait disabled:opacity-60">
          {saving ? '保存中…' : '保存场景'}
        </button>
        <Link href="/admin/scenes" className="btn-outline min-h-11">取消</Link>
      </div>
    </form>
  );
}
