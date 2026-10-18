import { randomUUID } from 'node:crypto';
import type { PrismaClient, CmsRevision } from '@prisma/client';
import { revalidatePath } from 'next/cache';
import { prisma } from './db';
import { requireCmsPermission, type AdminSession } from './auth';
import { FormValidationError } from './cms-inputs';
import { applyCmsSnapshot, cmsEditPermission, cmsEntityTypes, cmsPayloadToFormData,
  cmsSnapshotHash, prepareCmsSnapshot, readCmsSnapshot,
  type CmsEntityType, type CmsFormPayload, type CmsSnapshot, type CmsTx } from './cms-apply';
export { formDataToCmsPayload, cmsPayloadToFormData, cmsSnapshotHash } from './cms-apply';
export type { CmsEntityType, CmsFormPayload } from './cms-apply';

export type StageCmsRevisionInput = {
  entityType:CmsEntityType;entityId?:string|null;operation:'UPSERT'|'DELETE';title:string;
  payload:CmsFormPayload;expectedVersion?:number;expectedHash?:string;
};
type Authorize = (permission:string)=>Promise<AdminSession>;
function typeOf(value:string):CmsEntityType {
  if(!cmsEntityTypes.includes(value as CmsEntityType))throw new FormValidationError('不支持的内容类型');
  return value as CmsEntityType;
}
function snapshotOf(value:string|null):CmsSnapshot {
  if(!value)throw new FormValidationError('历史版本缺少完整快照，不能发布或恢复');
  const parsed:unknown=JSON.parse(value);
  if(!parsed||typeof parsed!=='object'||!('record' in parsed)||!('scope' in parsed))throw new FormValidationError('版本快照格式无效');
  const snapshot=parsed as CmsSnapshot;
  for(const key of ['variants','media','productMedia','sourceLinks','sceneBindings'] as const)
    if(!Array.isArray(snapshot[key]))throw new FormValidationError('版本关联快照不完整');
  if(!Array.isArray(snapshot.scope?.sourceIds)||!Array.isArray(snapshot.scope?.sceneIds))throw new FormValidationError('版本来源范围不完整');
  return snapshot;
}
const actorId=(actor:AdminSession)=>actor.actorId??`local:${actor.username}`;

/** Re-read the lease in the same transaction as the write, so revocation/expiry wins. */
async function assertCurrentActor(tx:CmsTx,actor:AdminSession,permission:string):Promise<void> {
  if(actor.source==='imp') {
    if(!actor.portalSessionId)throw new FormValidationError('官网编辑授权已失效，请从 IMP 重新进入');
    const lease=await tx.impPortalSession.findUnique({where:{id:actor.portalSessionId}});
    let permissions:unknown=[];
    try {permissions=lease?JSON.parse(lease.permissions):[];}catch {/* fail closed */}
    if(!lease||!lease.authSessionId||lease.revokedAt||lease.expiresAt.getTime()<=Date.now()||lease.actorId!==actor.actorId||
      !Array.isArray(permissions)||!permissions.includes('website:view')||!permissions.includes(permission))
      throw new FormValidationError('官网编辑授权已过期或权限已变化，请从 IMP 重新进入');
  } else if(!await tx.user.findUnique({where:{username:actor.username},select:{id:true}})) {
    throw new FormValidationError('后台账号已失效');
  }
}

/** Internal service: the default authorizer always verifies the actual signed session.
 * A transaction client is injected only by integration tests using an isolated database. */
export class CmsRevisionService {
  constructor(private readonly db:PrismaClient,private readonly authorize:Authorize=requireCmsPermission){}

  async baseHash(entityType:CmsEntityType,entityId:string):Promise<string> {
    return (await this.editState(entityType,entityId)).baseHash;
  }
  async editState(entityType:CmsEntityType,entityId:string):Promise<{snapshot:CmsSnapshot;baseHash:string}> {
    const type=typeOf(entityType),actor=await this.authorize(cmsEditPermission(type));
    return this.db.$transaction(async tx=>{
      await assertCurrentActor(tx,actor,cmsEditPermission(type));
      const snapshot=await readCmsSnapshot(tx,type,entityId);
      return {snapshot,baseHash:cmsSnapshotHash(snapshot)};
    },{isolationLevel:'Serializable'});
  }

  async stage(input:StageCmsRevisionInput):Promise<{revisionId:string;entityId:string}> {
    const type=typeOf(input.entityType),permission=cmsEditPermission(type),actor=await this.authorize(permission);
    if(input.operation!=='UPSERT'&&input.operation!=='DELETE')throw new FormValidationError('草稿操作无效');
    const form=cmsPayloadToFormData(input.payload);
    if(JSON.stringify(input.payload).length>512_000)throw new FormValidationError('草稿内容过大');
    const id=type==='setting'?String(input.entityId||form.get('settingKey')||''):input.entityId||randomUUID();
    if(!id||id.length>100)throw new FormValidationError('内容标识无效');
    return this.db.$transaction(async tx=>{
      await assertCurrentActor(tx,actor,permission);
      const before=await readCmsSnapshot(tx,type,id);
      if(input.entityId&&type!=='setting'&&!before.record)throw new FormValidationError('内容不存在或已删除');
      const hash=cmsSnapshotHash(before);
      const expectedHash=input.expectedHash??(typeof input.payload.expectedHash==='string'?input.payload.expectedHash:undefined);
      if(expectedHash&&expectedHash!==hash)throw new FormValidationError('编辑页面已过期，请刷新后重新核对内容');
      const rawVersion=input.expectedVersion??(typeof input.payload.rowVersion==='string'?Number(input.payload.rowVersion):undefined);
      if(before.record) {
        if(['product','series','resource'].includes(type)) {
          if(input.operation==='UPSERT'&&(!Number.isSafeInteger(rawVersion)||rawVersion!==before.record.rowVersion))
            throw new FormValidationError('内容版本已变化，请刷新后重新保存');
        } else if(!expectedHash)throw new FormValidationError('缺少编辑页面基准，请刷新后重试');
      }
      const after=await prepareCmsSnapshot(tx,type,id,input.operation,input.payload,before);
      await assertCurrentActor(tx,actor,permission);
      const title=input.title.trim().slice(0,200)||`${type} ${id}`;
      const revision=await tx.cmsRevision.create({data:{entityType:type,entityId:id,operation:input.operation,title,
        payload:JSON.stringify(input.payload),beforeState:JSON.stringify(before),afterState:JSON.stringify(after),
        baseHash:hash,baseVersion:typeof before.record?.rowVersion==='number'?before.record.rowVersion:null,
        createdBy:actorId(actor),status:'DRAFT'}});
      await tx.cmsAuditEvent.create({data:{actorId:actorId(actor),action:'DRAFT_CREATED',entityType:type,entityId:id,
        revisionId:revision.id,summary:`保存草稿：${title}`}});
      return {revisionId:revision.id,entityId:id};
    },{timeout:20_000,isolationLevel:'Serializable'});
  }

  async publish(revisionId:string):Promise<CmsRevision> {
    const actor=await this.authorize('website:publish');
    return this.db.$transaction(async tx=>{
      await assertCurrentActor(tx,actor,'website:publish');
      const revision=await tx.cmsRevision.findUnique({where:{id:revisionId}});
      if(!revision||revision.status!=='DRAFT'||!revision.entityId||!revision.baseHash)
        throw new FormValidationError('草稿不存在、已处理，或缺少可验证的版本基准');
      const type=typeOf(revision.entityType),before=snapshotOf(revision.beforeState),target=snapshotOf(revision.afterState);
      const current=await readCmsSnapshot(tx,type,revision.entityId,before.scope);
      if(cmsSnapshotHash(current)!==revision.baseHash)throw new FormValidationError('正式内容或关联数据已变化，请保存新草稿后再发布');
      const claimed=await tx.cmsRevision.updateMany({where:{id:revision.id,status:'DRAFT',baseHash:revision.baseHash},data:{status:'PUBLISHING'}});
      if(claimed.count!==1)throw new FormValidationError('该版本已由其他人员处理');
      await applyCmsSnapshot(tx,type,revision.entityId,target,current);
      await assertCurrentActor(tx,actor,'website:publish');
      const actual=await readCmsSnapshot(tx,type,revision.entityId,target.scope);
      const published=await tx.cmsRevision.update({where:{id:revision.id},data:{status:'PUBLISHED',publishedAt:new Date(),
        publishedBy:actorId(actor),afterState:JSON.stringify(actual)}});
      await tx.cmsAuditEvent.create({data:{actorId:actorId(actor),action:'PUBLISHED',entityType:type,entityId:revision.entityId,
        revisionId:revision.id,summary:`发布版本：${revision.title}`}});
      return published;
    },{timeout:20_000,isolationLevel:'Serializable'});
  }

  async rollback(revisionId:string):Promise<CmsRevision> {
    const actor=await this.authorize('website:rollback');
    return this.db.$transaction(async tx=>{
      await assertCurrentActor(tx,actor,'website:rollback');
      const original=await tx.cmsRevision.findUnique({where:{id:revisionId}});
      if(!original||original.status!=='PUBLISHED'||!original.entityId||!original.baseHash)
        throw new FormValidationError('该版本没有可恢复的发布记录');
      const type=typeOf(original.entityType),published=snapshotOf(original.afterState),target=snapshotOf(original.beforeState);
      const current=await readCmsSnapshot(tx,type,original.entityId,published.scope);
      if(cmsSnapshotHash(current)!==cmsSnapshotHash(published))
        throw new FormValidationError('此版本之后已有修改，不能覆盖后续内容；请基于当前版本保存新草稿');
      await applyCmsSnapshot(tx,type,original.entityId,target,current,true);
      await assertCurrentActor(tx,actor,'website:rollback');
      const actual=await readCmsSnapshot(tx,type,original.entityId,target.scope);
      const restored=await tx.cmsRevision.create({data:{entityType:type,entityId:original.entityId,operation:'ROLLBACK',
        title:`恢复：${original.title}`,payload:JSON.stringify({rollbackOf:original.id}),beforeState:JSON.stringify(current),
        afterState:JSON.stringify(actual),baseHash:cmsSnapshotHash(current),
        baseVersion:typeof current.record?.rowVersion==='number'?current.record.rowVersion:null,
        status:'PUBLISHED',createdBy:actorId(actor),publishedBy:actorId(actor),publishedAt:new Date()}});
      await tx.cmsAuditEvent.create({data:{actorId:actorId(actor),action:'ROLLED_BACK',entityType:type,entityId:original.entityId,
        revisionId:restored.id,summary:`恢复发布前内容：${original.id}`}});
      return restored;
    },{timeout:20_000,isolationLevel:'Serializable'});
  }

  async discard(revisionId:string):Promise<void> {
    const revision=await this.db.cmsRevision.findUnique({where:{id:revisionId}});
    if(!revision)throw new FormValidationError('草稿不存在');
    const type=typeOf(revision.entityType),permission=cmsEditPermission(type),actor=await this.authorize(permission);
    await this.db.$transaction(async tx=>{
      await assertCurrentActor(tx,actor,permission);
      const result=await tx.cmsRevision.updateMany({where:{id:revisionId,status:'DRAFT',createdBy:actorId(actor)},data:{status:'DISCARDED'}});
      if(result.count!==1)throw new FormValidationError('只能放弃自己尚未发布的草稿');
      await tx.cmsAuditEvent.create({data:{actorId:actorId(actor),action:'DRAFT_DISCARDED',entityType:type,entityId:revision.entityId,
        revisionId,summary:`放弃草稿：${revision.title}`}});
    },{isolationLevel:'Serializable'});
  }
}

const service=new CmsRevisionService(prisma);
export async function getCmsBaseHash(type:CmsEntityType,id:string):Promise<string> {return service.baseHash(type,id);}
export async function getCmsEditState(type:CmsEntityType,id:string) {return service.editState(type,id);}
export async function stageCmsRevision(input:StageCmsRevisionInput) {
  const result=await service.stage(input);invalidateAdminViews();return result;
}
function invalidateAdminViews(){try{revalidatePath('/admin','layout');}catch{console.warn('CMS admin cache refresh failed after revision committed');}}
function invalidatePublishedContent(){try{revalidatePath('/[locale]','layout');}catch{console.warn('CMS public cache refresh failed after revision committed');}invalidateAdminViews();}
export async function publishCmsRevision(id:string){const result=await service.publish(id);invalidatePublishedContent();return result;}
export async function rollbackCmsRevision(id:string){const result=await service.rollback(id);invalidatePublishedContent();return result;}
export async function discardCmsRevision(id:string){await service.discard(id);invalidateAdminViews();}
