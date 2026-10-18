'use client';
import { useState } from 'react';
export function MediaPath({ path }: { path: string }) {
  const [copied, setCopied] = useState(false);
  return <div><input value={path} readOnly aria-label="图片路径" className="input-uten text-xs" onFocus={e => e.currentTarget.select()} />
    <button className="mt-2 min-h-9 text-xs font-medium text-accent" type="button" onClick={async () => {
      try { await navigator.clipboard.writeText(path); setCopied(true); } catch { setCopied(false); }
    }}>{copied ? '已复制路径' : '复制图片路径'}</button></div>;
}
