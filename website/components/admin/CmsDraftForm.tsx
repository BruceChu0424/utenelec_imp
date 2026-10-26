'use client';

import { useState, useTransition, type ReactNode } from 'react';

export function CmsDraftForm({ action, children, className, id }: {
  action: (form: FormData) => Promise<{ error?: string } | void>;
  children: ReactNode; className?: string; id?: string;
}) {
  const [error,setError]=useState('');
  const [pending,start]=useTransition();
  return <form id={id} onSubmit={event=>{
    event.preventDefault();if(pending)return;
    const form=new FormData(event.currentTarget);
    start(async()=>{setError('');try{const result=await action(form);setError(result?.error??'');}
      catch{setError('未收到草稿保存确认，请先查看发布记录，再决定是否重试');}});
  }} className={className} aria-busy={pending}>
    <p className="mb-4 text-sm text-muted-foreground">保存后生成待审核版本。预览并发布该版本后，官网内容才会更新。</p>
    {pending&&<p role="status" className="mb-3 text-sm text-muted-foreground">正在保存草稿…</p>}
    {error && <p role="alert" className="mb-4 rounded-lg border border-destructive/30 bg-destructive/5 p-3 text-sm text-destructive">{error}</p>}
    <fieldset disabled={pending} className="min-w-0 border-0 p-0">{children}</fieldset>
  </form>;
}
