'use client';
import { useState, useTransition } from 'react';
import { uploadDocument, saveResource } from '@/app/admin/resource-actions';
import { ClientForm } from '@/components/forms/ClientForm';

type Initial = { id: string; rowVersion: number; assetId: string; i18n: string; language: string; version: string;
  market: string | null; productId: string | null; seriesId: string | null; published: boolean; asset: { originalName: string } };
export function ResourceForm({ initial, expectedHash, series, products }: {
  initial?: Initial; expectedHash: string; series: { id: string; name: string }[]; products: { id: string; name: string }[];
}) {
  const copy = initial ? JSON.parse(initial.i18n) : {};
  const [asset, setAsset] = useState({ id: initial?.assetId || '', name: initial?.asset.originalName || '' });
  const [error, setError] = useState(''); const [busy, start] = useTransition();
  const [uploading, setUploading] = useState(false);
  return <ClientForm className="mt-7 max-w-4xl space-y-6" onSubmit={event => {
    event.preventDefault(); if (busy || uploading) return; const form = new FormData(event.currentTarget);
    start(async () => { setError(''); try { const result = await saveResource(form); if (result?.error) setError(result.error); }
      catch { setError('暂时无法保存，已填写的内容仍保留，请检查连接后重试。'); } });
  }}>
    <input type="hidden" name="id" value={initial?.id || ''} /><input type="hidden" name="rowVersion" value={initial?.rowVersion || ''} />
    <input type="hidden" name="expectedHash" value={expectedHash} /><input type="hidden" name="assetId" value={asset.id} />
    <section className="card-uten space-y-4 p-6"><h2 className="font-semibold">资料文件</h2><p className="text-sm text-muted-foreground">PDF 文件保存在私有资料区，发布后才能从官网获取。最大 20 MB，不接受带脚本、自动动作或嵌入附件的文件。</p>
      <input type="file" accept="application/pdf,.pdf" aria-label="上传 PDF 文件" disabled={uploading || busy} onChange={async event => {
        const file = event.currentTarget.files?.[0]; if (!file) return;
        setUploading(true); setError(''); const data = new FormData(); data.set('file', file);
        try { const result = await uploadDocument(data);
          if (result.id) setAsset({ id: result.id, name: result.name || file.name }); else setError(result.error || '上传失败');
        } catch { setError('连接中断，文件尚未确认上传，请重试。'); } finally { setUploading(false); }
      }} /><p className="text-sm" role="status">{uploading ? '正在校验和保存文件…' : asset.name || '尚未选择文件'}</p>
    </section>
    <div className="grid gap-6 sm:grid-cols-2">{(['zh', 'en'] as const).map(locale => <fieldset className="card-uten space-y-4 p-6" key={locale}>
      <legend className="px-2 font-semibold">{locale === 'zh' ? '中文' : 'English'}</legend>
      <label className="label-uten" htmlFor={`${locale}-title`}>资料标题</label><input id={`${locale}-title`} name={`${locale}_title`} required={locale === 'zh'} maxLength={160} defaultValue={copy[locale]?.title || ''} className="input-uten" />
      <label className="label-uten" htmlFor={`${locale}-description`}>资料说明</label><textarea id={`${locale}-description`} name={`${locale}_description`} rows={4} maxLength={2000} defaultValue={copy[locale]?.description || ''} className="input-uten" />
    </fieldset>)}</div>
    <section className="card-uten grid gap-5 p-6 sm:grid-cols-2">
      <label className="label-uten">文件语言<select name="language" defaultValue={initial?.language || 'zh'} className="input-uten mt-2"><option value="zh">中文</option><option value="en">English</option><option value="es">Español</option><option value="fr">Français</option><option value="de">Deutsch</option><option value="pt">Português</option><option value="ar">العربية</option><option value="ru">Русский</option><option value="ja">日本語</option><option value="ko">한국어</option></select></label>
      <label className="label-uten">文件版本<input name="version" required maxLength={80} defaultValue={initial?.version || ''} placeholder="例如：2026-10" className="input-uten mt-2" /></label>
      <label className="label-uten">适用市场<input name="market" maxLength={120} defaultValue={initial?.market || ''} className="input-uten mt-2" /></label>
      <label className="label-uten">关联系列<select name="seriesId" defaultValue={initial?.seriesId || ''} className="input-uten mt-2"><option value="">通用资料</option>{series.map(s => <option key={s.id} value={s.id}>{s.name}</option>)}</select></label>
      <label className="label-uten sm:col-span-2">关联型号<select name="productId" defaultValue={initial?.productId || ''} className="input-uten mt-2"><option value="">不限定具体型号</option>{products.map(p => <option key={p.id} value={p.id}>{p.name}</option>)}</select></label>
      <label className="flex items-center gap-3 text-sm sm:col-span-2"><input type="checkbox" name="published" defaultChecked={initial?.published ?? true} />本次草稿通过发布后在官网展示</label>
    </section>
    {error && <p role="alert" className="text-sm text-destructive">{error}</p>}
    <button type="submit" disabled={busy || uploading || !asset.id} className="btn-accent">{busy ? '正在保存…' : '保存资料草稿'}</button>
  </ClientForm>;
}
