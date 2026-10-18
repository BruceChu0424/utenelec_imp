'use client';
import { useActionState } from 'react';
import { processRevision } from '@/app/admin/(protected)/releases/actions';
export function CmsRevisionActions({id,publish,rollback,discard,unchanged}:{id:string;publish:boolean;rollback:boolean;discard:boolean;unchanged:boolean}) {
  const [state,action,pending]=useActionState(async(_previous:{error?:string},form:FormData)=>processRevision(form),{});
  return <div className="mt-5">
    {!unchanged&&<p role="status" className="mb-3 rounded-lg border border-border bg-muted/40 p-3 text-sm">正式内容或关联数据已有后续修改。为保留这些修改，请重新打开编辑页并保存新草稿。</p>}
    <form action={action} className="flex flex-wrap gap-3"><input type="hidden" name="revisionId" value={id} />
      {publish&&<button name="operation" value="publish" disabled={pending||!unchanged} className="btn-accent disabled:opacity-40">{pending?'处理中':'发布此版本'}</button>}
      {rollback&&<button name="operation" value="rollback" disabled={pending||!unchanged} className="btn-outline disabled:opacity-40" onClick={event=>{
        if(!confirm('恢复到此版本发布前的内容？系统将校验当前版本、来源关系及发布层级，并保留新的恢复记录。'))event.preventDefault();
      }}>{pending?'处理中':'恢复此版本发布前内容'}</button>}
      {discard&&<button name="operation" value="discard" disabled={pending} className="btn-outline disabled:opacity-40">放弃此草稿</button>}
    </form>
    {state.error&&<p role="alert" className="mt-3 rounded-lg bg-destructive/5 p-3 text-sm text-destructive">{state.error}</p>}
  </div>;
}
