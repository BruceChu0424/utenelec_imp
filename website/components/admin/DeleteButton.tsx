'use client';
import { useTransition } from 'react';

export function DeleteButton({
  action, label = '删除', confirmText = '确认删除？此操作不可恢复。',
}: {
  action: () => Promise<void>;
  label?: string;
  confirmText?: string;
}) {
  const [pending, start] = useTransition();
  return (
    <button type="button" disabled={pending}
      onClick={() => { if (confirm(confirmText)) start(() => action()); }}
      className="text-destructive transition hover:underline disabled:opacity-50">
      {pending ? '删除中…' : label}
    </button>
  );
}
