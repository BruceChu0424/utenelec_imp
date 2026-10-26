'use client';
import { useState, useTransition } from 'react';

export function DeleteButton({
  action, label = '删除', confirmText = '确认删除？此操作不可恢复。',
  draft = false,
}: {
  action: () => Promise<void>;
  label?: string;
  confirmText?: string;
  draft?: boolean;
}) {
  const [pending, start] = useTransition();
  const [error, setError] = useState('');
  return (
    <span><button type="button" disabled={pending}
      onClick={() => { if (confirm(draft ? '将创建删除草稿，审核发布后才会生效。是否继续？' : confirmText)) start(async () => {
        setError('');try { await action(); }catch { setError('请求未完成，请检查版本状态后重试'); }
      }); }}
      className="text-destructive transition hover:underline disabled:opacity-50">
      {pending ? (draft ? '保存草稿中…' : '删除中…') : (draft ? '申请删除' : label)}
    </button>{error&&<span role="alert" className="ml-2 text-sm text-destructive">{error}</span>}</span>
  );
}
