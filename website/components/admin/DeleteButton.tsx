'use client';
import { useState, useTransition } from 'react';
import { ConfirmationDialog } from './ConfirmationDialog';

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
  const [confirming, setConfirming] = useState(false);
  return (
    <><span><button type="button" disabled={pending}
      onClick={() => setConfirming(true)}
      className="text-destructive transition hover:underline disabled:opacity-50">
      {pending ? (draft ? '保存草稿中…' : '删除中…') : (draft ? '申请删除' : label)}
    </button>{error&&<span role="alert" className="ml-2 text-sm text-destructive">{error}</span>}</span>
      <ConfirmationDialog open={confirming} title={draft ? '申请删除此内容？' : `确认${label}？`}
        description={draft ? '将创建删除草稿，审核发布后才会生效。现有公开内容在发布前保持不变。' : confirmText}
        confirmLabel={draft ? '保存删除草稿' : `确认${label}`} onCancel={() => setConfirming(false)}
        onConfirm={() => { setConfirming(false); start(async () => {
          setError(''); try { await action(); } catch { setError('请求未完成，请检查版本状态后重试'); }
        }); }} />
    </>
  );
}
