'use client';
import { useState, useRef, useTransition, type ChangeEvent } from 'react';
import { uploadImage } from '@/app/admin/actions';
import { Upload, Loader2, X } from 'lucide-react';

export function ImageUpload({ name, value = '' }: { name: string; value?: string }) {
  const [url, setUrl] = useState(value);
  const [pending, start] = useTransition();
  const [err, setErr] = useState('');
  const inputRef = useRef<HTMLInputElement>(null);
  const previewUrl = /^\/(?:uploads|images)\//.test(url) ? url : '';

  const onFile = (f: File) => {
    setErr('');
    const fd = new FormData();
    fd.append('file', f);
    start(async () => {
      const r = await uploadImage(fd);
      if (r.url) setUrl(r.url);
      else setErr(r.error || '上传失败');
    });
  };

  return (
    <div>
      <input type="hidden" name={name} value={url} />
      <div className="flex items-start gap-3">
        {previewUrl ? (
          <div className="relative">
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={previewUrl} alt="" className="h-24 w-24 rounded-lg border border-border object-cover" />
            <button type="button" onClick={() => setUrl('')}
              aria-label="移除图片"
              className="absolute -right-2 -top-2 grid h-6 w-6 place-items-center rounded-full bg-destructive text-white">
              <X className="h-3 w-3" />
            </button>
          </div>
        ) : (
          <button type="button" onClick={() => inputRef.current?.click()} disabled={pending}
            className="flex h-24 w-24 flex-col items-center justify-center gap-1 rounded-lg border-2 border-dashed border-border text-muted-foreground transition hover:border-accent hover:text-accent disabled:opacity-50">
            {pending ? <Loader2 className="h-5 w-5 animate-spin" /> : <Upload className="h-5 w-5" />}
            <span className="text-xs">{pending ? '上传中' : '上传'}</span>
          </button>
        )}
        <div className="flex-1">
          <input type="text" value={url} onChange={(e: ChangeEvent<HTMLInputElement>) => setUrl(e.target.value)}
            placeholder="上传后自动填入, 或粘贴路径如 /images/raw/xxx.png"
            className="input-uten text-xs" />
          {err && <p className="mt-1 text-xs text-destructive">{err}</p>}
          {url && !previewUrl && <p className="mt-1 text-xs text-destructive">仅允许 /uploads/ 或 /images/ 下的站内图片路径</p>}
          <p className="mt-1 text-xs text-muted-foreground">支持上传图片或填写已有站内路径</p>
        </div>
      </div>
      <input ref={inputRef} type="file" accept="image/jpeg,image/png,image/webp,image/gif" className="hidden"
        onChange={(e) => { const f = e.target.files?.[0]; if (f) onFile(f); }} />
    </div>
  );
}
