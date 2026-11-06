'use client';
import { useCallback, useRef, useState, useTransition } from 'react';
import { ConfirmationDialog } from './ConfirmationDialog';
import { CmsBusyDialog } from './CmsBusyDialog';

let deletionInFlight = false;

export function DeleteButton({
  action, label = '删除', confirmText = '确认删除？此操作不可恢复。', draft = false,
}: { action: () => Promise<void>; label?: string; confirmText?: string; draft?: boolean }) {
  const [pending, start] = useTransition();
  const [error, setError] = useState('');
  const [confirming, setConfirming] = useState(false);
  const inFlight = useRef(false);
  const button = useRef<HTMLButtonElement>(null);
  const restoreFocus = useCallback(() => button.current?.focus(), []);
  function confirm() {
    if (inFlight.current || deletionInFlight) return;
    inFlight.current = true; deletionInFlight = true;
    setConfirming(false);
    start(async () => {
      setError('');
      try { await action(); }
      catch { setError('请求未完成，请检查版本状态后重试'); }
      finally { inFlight.current = false; deletionInFlight = false; }
    });
  }
  return <>
    <span><button ref={button} type="button" disabled={pending}
      onClick={() => { if (!inFlight.current && !deletionInFlight) setConfirming(true); }}
      className="text-destructive transition hover:underline disabled:opacity-50">
      {pending ? (draft ? '保存草稿中…' : '删除中…') : (draft ? '申请删除' : label)}
    </button>{error && <span role="alert" className="ml-2 text-sm text-destructive">{error}</span>}</span>
    {confirming && <ConfirmationDialog open title={draft ? '申请删除此内容？' : `确认${label}？`}
      description={draft ? '将创建删除草稿，审核发布后才会生效。现有公开内容在发布前保持不变。' : confirmText}
      confirmLabel={draft ? '保存删除草稿' : `确认${label}`} onCancel={() => { setConfirming(false); requestAnimationFrame(restoreFocus); }} onConfirm={confirm} />}
    {pending && <CmsBusyDialog label={draft ? '正在保存删除草稿' : '正在删除'} onClosed={restoreFocus} />}
  </>;
}
