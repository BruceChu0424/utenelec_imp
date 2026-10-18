'use server';
import { publishCmsRevision,rollbackCmsRevision,discardCmsRevision } from '@/lib/cms-revisions';
import { FormValidationError } from '@/lib/cms-inputs';
import { redirect } from 'next/navigation';
export async function processRevision(form:FormData):Promise<{error?:string}> {
  const id=String(form.get('revisionId')||''),operation=String(form.get('operation')||'');
  if(!id||id.length>100)return {error:'版本标识无效'};
  let destination=id;
  try {
    if(operation==='publish')await publishCmsRevision(id);
    else if(operation==='rollback')destination=(await rollbackCmsRevision(id)).id;
    else if(operation==='discard')await discardCmsRevision(id);
    else return {error:'版本操作无效'};
  }catch(error){return {error:error instanceof FormValidationError?error.message:'版本操作未完成，请刷新查看状态后重试'};}
  redirect(`/admin/releases/${destination}`);
}
