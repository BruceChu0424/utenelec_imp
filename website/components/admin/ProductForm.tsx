'use client';
import { useState, type FormEvent } from 'react';
import { saveProduct } from '@/app/admin/actions';
import { ImageUpload } from './ImageUpload';
import { tr } from '@/lib/content';

type SeriesLite = { id: string; code: string; name: string };
type Product = { id: string; image: string | null; featured: boolean; series: { code: string } | null; i18n: string | null } | null;

export function ProductForm({ product, series }: { product: Product; series: SeriesLite[] }) {
  const zh = product ? tr<{ name: string; description?: string }>(product.i18n, 'zh') : { name: '', description: '' };
  const en = product ? tr<{ name: string; description?: string }>(product.i18n, 'en') : { name: '', description: '' };
  const [err, setErr] = useState('');
  const [saving, setSaving] = useState(false);

  const onSubmit = (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    setErr(''); setSaving(true);
    const fd = new FormData(e.currentTarget);
    saveProduct(fd).then((r) => { if (r && r.error) { setErr(r.error); setSaving(false); } });
  };

  return (
    <form onSubmit={onSubmit} className="max-w-2xl">
      <h1 className="font-heading text-2xl font-bold">{product ? '编辑产品' : '新增产品'}</h1>
      {err && <div className="mt-4 rounded-lg bg-destructive/10 px-3 py-2 text-sm text-destructive">{err}</div>}

      <div className="mt-5 card-uten space-y-4 p-5">
        <div>
          <label className="label-uten">所属系列</label>
          <select name="seriesCode" defaultValue={product?.series?.code || ''} className="input-uten">
            <option value="">(无系列)</option>
            {series.map((s) => <option key={s.id} value={s.code}>{s.name}</option>)}
          </select>
        </div>
        <div>
          <label className="label-uten">产品图片</label>
          <ImageUpload name="image" value={product?.image || ''} />
        </div>
        <label className="flex items-center gap-2 text-sm font-medium">
          <input type="checkbox" name="featured" defaultChecked={product?.featured} className="h-4 w-4 rounded border-border" />
          设为首页推荐
        </label>
      </div>

      <fieldset className="mt-5 card-uten space-y-3 border-l-4 border-l-accent p-5">
        <legend className="px-2 text-sm font-bold text-accent">中文</legend>
        <div><label className="label-uten">产品名称 *</label><input name="zh_name" required defaultValue={zh.name} className="input-uten" /></div>
        <div><label className="label-uten">产品描述</label><textarea name="zh_desc" rows={3} defaultValue={zh.description} className="input-uten resize-none" /></div>
      </fieldset>

      <fieldset className="mt-5 card-uten space-y-3 border-l-4 border-l-accent p-5">
        <legend className="px-2 text-sm font-bold text-accent">English</legend>
        <div><label className="label-uten">Product Name</label><input name="en_name" defaultValue={en.name} className="input-uten" /></div>
        <div><label className="label-uten">Description</label><textarea name="en_desc" rows={3} defaultValue={en.description} className="input-uten resize-none" /></div>
        <p className="text-xs text-muted-foreground">不填则默认使用中文名称</p>
      </fieldset>

      {product && <input type="hidden" name="id" value={product.id} />}
      <div className="mt-6 flex gap-3">
        <button type="submit" disabled={saving} className="btn-accent">{saving ? '保存中…' : '保存产品'}</button>
        <a href="/admin/products" className="btn-outline">取消</a>
      </div>
    </form>
  );
}
