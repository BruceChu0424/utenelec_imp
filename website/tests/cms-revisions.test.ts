import assert from 'node:assert/strict';
import { before,after,test } from 'node:test';
import { randomUUID, randomBytes } from 'node:crypto';
import { PrismaClient } from '@prisma/client';
import { migratedDatabase } from './helpers/migrated-database';
import { createIsolatedPostgresqlDatabase,postgresqlTestsEnabled } from './helpers/isolated-postgresql';
import { cmsSnapshotHash,formDataToCmsPayload,cmsPayloadToFormData,type CmsFormPayload } from '../lib/cms-apply';
import type { AdminSession } from '../lib/auth';

let temporary:{databaseUrl:string;dispose:()=>Promise<void>};
let db:PrismaClient;
let CmsRevisionService:typeof import('../lib/cms-revisions').CmsRevisionService;
const previousDatabaseUrl=process.env.DATABASE_URL;
const all=['website:view','website:content_edit','website:product_edit','website:media_manage','website:publish','website:rollback'];
before(async()=>{
  if(postgresqlTestsEnabled()) {
    const isolated=await createIsolatedPostgresqlDatabase('core');temporary=isolated;
    db=isolated.client as unknown as PrismaClient;
  } else {temporary=await migratedDatabase();db=new PrismaClient({datasources:{db:{url:temporary.databaseUrl}}});}
  process.env.DATABASE_URL=temporary.databaseUrl;
  CmsRevisionService=(await import('../lib/cms-revisions')).CmsRevisionService;
});
after(async()=>{
  await db?.$disconnect();
  if(temporary) {await (await import('../lib/db')).prisma.$disconnect();await temporary.dispose();}
  if(previousDatabaseUrl===undefined)delete process.env.DATABASE_URL;else process.env.DATABASE_URL=previousDatabaseUrl;
});
async function actor(permissions=all) {
  const lease=await db.impPortalSession.create({data:{id:randomUUID(),actorId:randomUUID(),authSessionId:randomUUID(),displayName:'Integration editor',permissions:JSON.stringify(permissions),siteId:'test',expiresAt:new Date(Date.now()+240_000)}});
  const session:AdminSession={source:'imp',username:lease.displayName,actorId:lease.actorId,portalSessionId:lease.id,permissions};
  const service=new CmsRevisionService(db,async permission=>{if(!permissions.includes(permission))throw new Error('permission denied');return session;});
  return {service,lease};
}
async function productFixture({published=true,scene=false}={}) {
  const family=await db.series.create({data:{code:`f-${randomUUID()}`,catalogRole:'FAMILY',published:true,i18n:'{"zh":{"name":"测试系列"}}'}});
  const product=await db.product.create({data:{slug:`p-${randomUUID()}`,seriesId:family.id,published,sceneEnabled:scene,
    i18n:'{"zh":{"name":"原产品","description":"原说明"},"fr":{"name":"Original FR"}}',sourceIdentity:`source:${randomUUID()}`}});
  const variant=await db.productVariant.create({data:{productId:product.id,i18n:'{"zh":{"name":"原款式"}}',image:'/images/test.webp',published:true,isDefault:true,
    sourceIdentity:`variant:${randomUUID()}`,dataStatus:'NEEDS_REVIEW'}});
  let sceneId:string|undefined;
  if(scene)sceneId=(await db.scenePreset.create({data:{slug:`s-${randomUUID()}`,i18n:'{"zh":{"name":"场景"}}',backgroundImage:'/images/wall.webp',config:'{}',defaultVariantId:variant.id,published:true}})).id;
  return {family,product,variant,sceneId};
}
function productForm(f:Awaited<ReturnType<typeof productFixture>>,extra:CmsFormPayload={}):CmsFormPayload {
  return {id:f.product.id,rowVersion:String(f.product.rowVersion),seriesCode:f.family.code,zh_name:'新产品',zh_desc:'新说明',
    published:'on',sceneEnabled:f.product.sceneEnabled?'on':'',variantKey:['base'],defaultVariantKey:'base',
    variant_base_id:f.variant.id,variant_base_zh_name:'新款式',variant_base_image:'/images/test.webp',
    variant_base_published:'on',variant_base_dataStatus:'NEEDS_REVIEW',...extra};
}

test('draft form conversion retains repeated variants and specification rows',()=>{
  const form=new FormData();form.append('variantKey','a');form.append('variantKey','b');form.append('spec_zh_label','额定电流');form.append('spec_zh_label','电压');
  const roundtrip=cmsPayloadToFormData(formDataToCmsPayload(form));
  assert.deepEqual(roundtrip.getAll('variantKey'),['a','b']);assert.deepEqual(roundtrip.getAll('spec_zh_label'),['额定电流','电压']);
});
test('saving a draft changes no public content; publisher applies the exact saved version',async()=>{
  const {service}=await actor(),f=await productFixture();
  const original=await db.product.findUniqueOrThrow({where:{id:f.product.id}});
  const revision=await service.stage({entityType:'product',entityId:f.product.id,operation:'UPSERT',title:'产品改版',payload:productForm(f)});
  assert.deepEqual(await db.product.findUniqueOrThrow({where:{id:f.product.id}}),original);
  assert.equal((await db.productVariant.findUniqueOrThrow({where:{id:f.variant.id}})).i18n,f.variant.i18n);
  const stored=await db.cmsRevision.findUniqueOrThrow({where:{id:revision.revisionId}});
  const preview=JSON.parse(stored.afterState!);assert.equal(JSON.parse(preview.record.i18n).zh.name,'新产品');
  await service.publish(revision.revisionId);
  const published=await db.product.findUniqueOrThrow({where:{id:f.product.id}});
  assert.equal(JSON.parse(published.i18n).zh.name,'新产品');assert.equal(JSON.parse(published.i18n).fr.name,'Original FR');
  assert.equal(published.sourceIdentity,original.sourceIdentity);assert.equal(published.rowVersion,2);
  assert.equal((await db.cmsRevision.findUniqueOrThrow({where:{id:revision.revisionId}})).status,'PUBLISHED');
  assert.equal(await db.cmsAuditEvent.count({where:{revisionId:revision.revisionId,action:'PUBLISHED'}}),1);
});
test('an editor cannot publish and a revoked or expired lease cannot stage',async()=>{
  const {service,lease}=await actor(['website:view','website:product_edit']),f=await productFixture();
  const revision=await service.stage({entityType:'product',entityId:f.product.id,operation:'UPSERT',title:'edit',payload:productForm(f)});
  await assert.rejects(service.publish(revision.revisionId),/permission denied/);
  await db.impPortalSession.update({where:{id:lease.id},data:{expiresAt:new Date(0)}});
  await assert.rejects(service.stage({entityType:'product',entityId:f.product.id,operation:'UPSERT',title:'expired',payload:productForm(f)}),/过期/);
  await db.impPortalSession.update({where:{id:lease.id},data:{expiresAt:new Date(Date.now()+60000),revokedAt:new Date()}});
  await assert.rejects(service.stage({entityType:'product',entityId:f.product.id,operation:'UPSERT',title:'revoked',payload:productForm(f)}),/过期/);
  assert.equal((await db.cmsRevision.findUniqueOrThrow({where:{id:revision.revisionId}})).status,'DRAFT');
});
test('a later publication conflicts with older drafts and failed publication keeps both content and draft intact',async()=>{
  const {service}=await actor(),f=await productFixture();
  const input={entityType:'product' as const,entityId:f.product.id,operation:'UPSERT' as const,title:'edit',payload:productForm(f)};
  const a=await service.stage(input),b=await service.stage({...input,payload:productForm(f,{zh_name:'另一版本'})});
  await service.publish(a.revisionId);
  await assert.rejects(service.publish(b.revisionId),/正式内容或关联数据已变化/);
  assert.equal(JSON.parse((await db.product.findUniqueOrThrow({where:{id:f.product.id}})).i18n).zh.name,'新产品');
  assert.equal((await db.cmsRevision.findUniqueOrThrow({where:{id:b.revisionId}})).status,'DRAFT');
  await assert.rejects(service.publish(a.revisionId),/已处理/);
});
test('parent publication gates are checked again at publish and a failed transaction leaves the prior version',async()=>{
  const {service}=await actor(),f=await productFixture();
  const r=await service.stage({entityType:'product',entityId:f.product.id,operation:'UPSERT',title:'edit',payload:productForm(f)});
  await db.series.update({where:{id:f.family.id},data:{published:false}});
  await assert.rejects(service.publish(r.revisionId),/FAMILY/);
  assert.equal((await db.cmsRevision.findUniqueOrThrow({where:{id:r.revisionId}})).status,'DRAFT');
  assert.equal(JSON.parse((await db.product.findUniqueOrThrow({where:{id:f.product.id}})).i18n).zh.name,'原产品');
});
test('rollback restores stable product, variant, source identity and scene bindings without rewinding row versions',async()=>{
  const {service}=await actor(),f=await productFixture({published:true,scene:true});
  const r=await service.stage({entityType:'product',entityId:f.product.id,operation:'UPSERT',title:'下架',payload:productForm(f,{published:'',sceneEnabled:''})});
  await service.publish(r.revisionId);
  assert.equal((await db.scenePreset.findUniqueOrThrow({where:{id:f.sceneId!}})).defaultVariantId,null);
  const rolled=await service.rollback(r.revisionId);
  const restored=await db.product.findUniqueOrThrow({where:{id:f.product.id}});
  assert.equal(restored.id,f.product.id);assert.equal(restored.sourceIdentity,f.product.sourceIdentity);assert.equal(restored.rowVersion,3);
  assert.equal(restored.published,true);assert.equal(JSON.parse(restored.i18n).zh.name,'原产品');
  assert.equal((await db.productVariant.findUniqueOrThrow({where:{id:f.variant.id}})).sourceIdentity,f.variant.sourceIdentity);
  assert.equal((await db.scenePreset.findUniqueOrThrow({where:{id:f.sceneId!}})).defaultVariantId,f.variant.id);
  assert.equal(rolled.operation,'ROLLBACK');assert.equal(await db.productVariant.count({where:{productId:f.product.id}}),1);
});
test('rollback does not override a later scene edit or bypass a parent taken offline',async()=>{
  const {service}=await actor(),f=await productFixture({published:true,scene:true});
  const r=await service.stage({entityType:'product',entityId:f.product.id,operation:'UPSERT',title:'下架',payload:productForm(f,{published:'',sceneEnabled:''})});
  await service.publish(r.revisionId);
  await db.scenePreset.update({where:{id:f.sceneId!},data:{i18n:'{"zh":{"name":"另一个编辑者的场景"}}'}});
  await assert.rejects(service.rollback(r.revisionId),/已有修改/);
  const other=await productFixture(),r2=await service.stage({entityType:'product',entityId:other.product.id,operation:'UPSERT',title:'下架',payload:productForm(other,{published:''})});
  await service.publish(r2.revisionId);await db.series.update({where:{id:other.family.id},data:{published:false}});
  await assert.rejects(service.rollback(r2.revisionId),/FAMILY/);
  assert.equal((await db.product.findUniqueOrThrow({where:{id:other.product.id}})).published,false);
});
test('news and setting use the editor snapshot hash and do not clobber another edit',async()=>{
  const {service}=await actor();
  const news=await db.news.create({data:{slug:`n-${randomUUID()}`,i18n:'{"zh":{"title":"原新闻"}}'}});
  const baseline=await service.baseHash('news',news.id);
  await db.news.update({where:{id:news.id},data:{i18n:'{"zh":{"title":"其它编辑者"}}'}});
  await assert.rejects(service.stage({entityType:'news',entityId:news.id,operation:'UPSERT',title:'stale',payload:{zh_title:'旧页面提交',expectedHash:baseline}}),/编辑页面已过期/);
  await db.setting.upsert({where:{key:'contact'},create:{key:'contact',i18n:'{"zh":{"company":"原公司"},"fr":{"company":"FR"}}'},update:{i18n:'{"zh":{"company":"原公司"},"fr":{"company":"FR"}}'}});
  const hash=await service.baseHash('setting','contact');
  const r=await service.stage({entityType:'setting',entityId:'contact',operation:'UPSERT',title:'联系信息',payload:{settingKey:'contact',expectedHash:hash,zh_company:'新公司'}});
  assert.equal(JSON.parse((await db.setting.findUniqueOrThrow({where:{key:'contact'}})).i18n).zh.company,'原公司');
  await service.publish(r.revisionId);
  assert.equal(JSON.parse((await db.setting.findUniqueOrThrow({where:{key:'contact'}})).i18n).fr.company,'FR');
});
test('new draft identities are reserved and publishing then rolling back a creation retains a recoverable exact identity',async()=>{
  const {service}=await actor();
  const r=await service.stage({entityType:'case',operation:'UPSERT',title:'新案例',payload:{zh_title:'新案例',zh_content:'经审核的说明'}});
  assert.equal(await db.caseItem.findUnique({where:{id:r.entityId}}),null);
  await service.publish(r.revisionId);assert.ok(await db.caseItem.findUnique({where:{id:r.entityId}}));
  const undo=await service.rollback(r.revisionId);assert.equal(await db.caseItem.findUnique({where:{id:r.entityId}}),null);
  await service.rollback(undo.id);assert.equal((await db.caseItem.findUniqueOrThrow({where:{id:r.entityId}})).id,r.entityId);
});
test('resource publication checks the immutable asset and product/series scope; linked resources prevent product deletion',async()=>{
  const {service}=await actor(),f=await productFixture({published:false});
  const asset=await db.websiteDocumentAsset.create({data:{storageKey:randomUUID(),sha256:'a'.repeat(64),mimeType:'application/pdf',originalName:'fixture.pdf',sizeBytes:10,createdBy:'fixture'}});
  const body={zh_title:'技术资料',language:'zh',version:'1',assetId:asset.id,productId:f.product.id,seriesId:f.family.id,published:'on'};
  await assert.rejects(service.stage({entityType:'resource',operation:'UPSERT',title:'资料',payload:body}),/尚未公开/);
  const r=await service.stage({entityType:'resource',operation:'UPSERT',title:'资料',payload:{...body,published:''}});
  await service.publish(r.revisionId);
  await assert.rejects(service.stage({entityType:'product',entityId:f.product.id,operation:'DELETE',title:'delete',payload:{}}),/关联资料/);
});
test('a missing legacy base hash fails closed and snapshots hash property order consistently',async()=>{
  assert.equal(cmsSnapshotHash({b:2,a:1}),cmsSnapshotHash({a:1,b:2}));
  const {service,lease}=await actor();
  const legacy=await db.cmsRevision.create({data:{entityType:'job',entityId:'not-real',operation:'UPSERT',title:'legacy',payload:'{}',createdBy:lease.actorId}});
  await assert.rejects(service.publish(legacy.id),/版本基准/);
});

test('delete and rollback preserve raw source records and restore media relationships with the original IDs',async()=>{
  const {service}=await actor(),f=await productFixture({published:false});
  const run=await db.legacyImportRun.create({data:{id:randomUUID(),sourceSystem:'fixture',schemaVersion:'fixture-v1',
    catalogSha256:'a'.repeat(64),mediaSha256:'b'.repeat(64),qaReportSha256:'c'.repeat(64),checkpointSha256:'d'.repeat(64),
    bundleSha256:randomBytes(32).toString('hex'),qaStatus:'PASS',expectFull:true,inputRoot:'synthetic',backupPath:'synthetic',stats:'{}'}});
  const source=await db.legacySourceRecord.create({data:{importRunId:run.id,sourceSystem:'fixture',entityType:'product',sourceId:f.product.id,
    locale:'zh',identityKey:`fixture:${f.product.id}`,sourceUrl:'https://example.invalid/fixture',sourceHash:'e'.repeat(64),
    rawPayload:'{"unalteredOriginal":"source evidence"}',productId:f.product.id,variantId:f.variant.id}});
  const asset=await db.legacyMediaAsset.create({data:{sha256:randomBytes(32).toString('hex'),mimeType:'image/webp',extension:'.webp',bytes:10,
    sourcePath:'synthetic',sourceUrls:'[]',sourceRefs:'[]'}});
  const media=await db.productMedia.create({data:{id:randomUUID(),productId:f.product.id,variantId:f.variant.id,assetId:asset.id,role:'main'}});
  const revision=await service.stage({entityType:'product',entityId:f.product.id,operation:'DELETE',title:'删除测试',payload:{}});
  await service.publish(revision.revisionId);
  assert.equal(await db.product.findUnique({where:{id:f.product.id}}),null);
  const detached=await db.legacySourceRecord.findUniqueOrThrow({where:{id:source.id}});
  assert.equal(detached.productId,null);assert.equal(detached.variantId,null);assert.equal(detached.rawPayload,source.rawPayload);
  await service.rollback(revision.revisionId);
  const restored=await db.legacySourceRecord.findUniqueOrThrow({where:{id:source.id}});
  assert.equal(restored.productId,f.product.id);assert.equal(restored.variantId,f.variant.id);assert.equal(restored.rawPayload,source.rawPayload);
  const restoredMedia=await db.productMedia.findUniqueOrThrow({where:{id:media.id}});
  assert.equal(restoredMedia.assetId,asset.id);assert.equal(restoredMedia.variantId,f.variant.id);
  assert.equal((await db.productVariant.findUniqueOrThrow({where:{id:f.variant.id}})).sourceIdentity,f.variant.sourceIdentity);
});

test('series, scene, job and hero edits all remain drafts until an exact revision is published',async()=>{
  const {service}=await actor();
  const created=await service.stage({entityType:'series',operation:'UPSERT',title:'系列草稿',payload:{
    code:`family-${randomUUID()}`,catalogRole:'FAMILY',zh_name:'系列草稿',published:'on',seriesMediaKey:['cover'],
    seriesMedia_cover_role:'combination',seriesMedia_cover_image:'/images/family.webp',seriesMedia_cover_published:'on'}});
  assert.equal(await db.series.findUnique({where:{id:created.entityId}}),null);
  const version=await db.cmsRevision.findUniqueOrThrow({where:{id:created.revisionId}}),reserved=JSON.parse(version.afterState!).media[0].id;
  await service.publish(created.revisionId);
  assert.equal((await db.seriesMedia.findFirstOrThrow({where:{seriesId:created.entityId}})).id,reserved);
  const scene=await service.stage({entityType:'scene',operation:'UPSERT',title:'场景',payload:{slug:`scene-${randomUUID()}`,zh_name:'场景',backgroundImage:'/images/wall.webp',published:'on'}});
  assert.equal(await db.scenePreset.findUnique({where:{id:scene.entityId}}),null);await service.publish(scene.revisionId);
  const job=await service.stage({entityType:'job',operation:'UPSERT',title:'岗位',payload:{zh_title:'测试岗位',zh_description:'测试岗位说明'}});
  assert.equal(await db.job.findUnique({where:{id:job.entityId}}),null);await service.publish(job.revisionId);
  const initial=await service.baseHash('setting','hero');
  const hero=await service.stage({entityType:'setting',entityId:'hero',operation:'UPSERT',title:'首页',payload:{settingKey:'hero',expectedHash:initial,
    zh_title:'首页标题',heroImage:'/images/hero.webp',heroSeriesId:created.entityId}});
  assert.equal(await db.setting.findUnique({where:{key:'hero'}}),null);await service.publish(hero.revisionId);
  const content=JSON.parse((await db.setting.findUniqueOrThrow({where:{key:'hero'}})).i18n);
  assert.equal(content.zh.heroImage,'/images/hero.webp');assert.equal(content.zh.heroSeriesId,created.entityId);
});

test('two simultaneous publishers cannot apply the same revision twice',async()=>{
  const {service}=await actor(),f=await productFixture();
  const revision=await service.stage({entityType:'product',entityId:f.product.id,operation:'UPSERT',title:'并发发布',payload:productForm(f)});
  const results=await Promise.allSettled([service.publish(revision.revisionId),service.publish(revision.revisionId)]);
  assert.equal(results.filter(r=>r.status==='fulfilled').length,1);
  assert.equal((await db.product.findUniqueOrThrow({where:{id:f.product.id}})).rowVersion,2);
  assert.equal(await db.cmsAuditEvent.count({where:{revisionId:revision.revisionId,action:'PUBLISHED'}}),1);
});

test('case, news and job explicitly stage false, publish visibility changes and restore stable content identities',async()=>{
  const {service}=await actor();
  for(const type of ['case','news','job'] as const) {
    const fields=type==='case'?{location:'原地点',content:'原正文\n\n第二段'}:
      type==='news'?{summary:'原摘要',content:'原正文\n\n第二段'}:{description:'原描述',requirements:'原要求'};
    const i18n=JSON.stringify({zh:{title:'原始标题',...fields},en:{title:'Original title',...fields},fr:{title:'Preserved original locale'}});
    const slug=`visibility-${type}-${randomUUID()}`;
    const original=type==='case'?await db.caseItem.create({data:{slug,i18n,published:true}}):
      type==='news'?await db.news.create({data:{slug,i18n,published:true,category:'company',publishedAt:new Date('2026-10-01T00:00:00Z')}}):
      await db.job.create({data:{slug,i18n,published:true}});
    const record=async()=>(await service.editState(type,original.id)).snapshot.record!;
    const payload:CmsFormPayload={};
    for(const locale of ['zh','en'])for(const[key,value]of Object.entries(JSON.parse(i18n)[locale]))payload[`${locale}_${key}`]=String(value);
    if(type==='news'){payload.category='company';payload.publishedAt='2026-10-01';}
    const stage=async(published:boolean)=>{
      const value=published?'on':'false';
      const form=cmsPayloadToFormData({...payload,published:value,expectedHash:await service.baseHash(type,original.id)});
      assert.equal(form.has('published'),true);assert.equal(form.get('published'),value);
      return service.stage({entityType:type,entityId:original.id,operation:'UPSERT',title:'展示状态草稿',payload:formDataToCmsPayload(form)});
    };
    const hidden=await stage(false);
    assert.equal((await record()).published,true,'saving a false draft must not change the public record');
    await service.publish(hidden.revisionId);
    assert.equal((await record()).published,false);
    await service.rollback(hidden.revisionId);
    const restored=await record();
    assert.equal(restored.id,original.id);assert.equal(restored.slug,slug);assert.equal(restored.published,true);
    assert.deepEqual(JSON.parse(String(restored.i18n)),JSON.parse(i18n));
    const hiddenAgain=await stage(false);await service.publish(hiddenAgain.revisionId);
    const shownAgain=await stage(true);
    assert.equal((await record()).published,false,'saving a true draft must not republish it');
    await service.publish(shownAgain.revisionId);
    assert.equal((await record()).published,true);assert.equal((await record()).id,original.id);
  }
});
