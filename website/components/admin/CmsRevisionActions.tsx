'use client';
import { useActionState, useRef, useState } from 'react';
import { processRevision } from '@/app/admin/(protected)/releases/actions';
import { ConfirmationDialog } from './ConfirmationDialog';
export function CmsRevisionActions({id,publish,rollback,discard,unchanged}:{id:string;publish:boolean;rollback:boolean;discard:boolean;unchanged:boolean}) {
  const [state,action,pending]=useActionState(async(_previous:{error?:string},form:FormData)=>processRevision(form),{});
  const form = useRef<HTMLFormElement>(null);
  const rollbackButton = useRef<HTMLButtonElement>(null);
  const [confirmRollback, setConfirmRollback] = useState(false);
  return <div className="mt-5">
    {!unchanged&&<p role="status" className="mb-3 rounded-lg border border-border bg-muted/40 p-3 text-sm">正式内容或关联数据已有后续修改。为保留这些修改，请重新打开编辑页并保存新草稿。</p>}
    <form ref={form} action={action} className="flex flex-wrap gap-3"><input type="hidden" name="revisionId" value={id} />
      {publish&&<button name="operation" value="publish" disabled={pending||!unchanged} className="btn-accent disabled:opacity-40">{pending?'处理中':'发布此版本'}</button>}
      {rollback&&<><button type="button" disabled={pending||!unchanged} className="btn-outline disabled:opacity-40"
        onClick={() => setConfirmRollback(true)}>{pending?'处理中':'恢复此版本发布前内容'}</button>
        <button ref={rollbackButton} type="submit" name="operation" value="rollback" hidden tabIndex={-1} aria-hidden="true" disabled={pending||!unchanged} />
      </>}
      {discard&&<button name="operation" value="discard" disabled={pending} className="btn-outline disabled:opacity-40">放弃此草稿</button>}
    </form>
    <ConfirmationDialog open={confirmRollback} title="恢复发布前内容？"
      description="系统将校验当前版本、来源关系及发布层级，恢复成功后保留一条新的版本记录。后续已经修改的内容不会被直接覆盖。"
      confirmLabel="确认恢复" onCancel={() => setConfirmRollback(false)} onConfirm={() => {
        setConfirmRollback(false);
        if (!pending && unchanged && form.current && rollbackButton.current) form.current.requestSubmit(rollbackButton.current);
      }} />
    {state.error&&<p role="alert" className="mt-3 rounded-lg bg-destructive/5 p-3 text-sm text-destructive">{state.error}</p>}
  </div>;
}
