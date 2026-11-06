import assert from 'node:assert/strict';
import test from 'node:test';
import { PrismaClient } from '@prisma/client';
import { migratedDatabase } from './helpers/migrated-database';
import { createIsolatedPostgresqlDatabase, postgresqlTestsEnabled } from './helpers/isolated-postgresql';
import { cmsCaptionJson, completeCmsRows } from '../lib/cms-read';
import { readCmsCases, readCmsInquiries, readCmsJobs, readCmsMedia, readCmsNews, readCmsProducts, readCmsReleases, readCmsResources, readCmsScenes, readCmsSeries } from '../lib/cms-list-queries';
import { productSearchPage } from '../lib/product-search';

const n=250,id=(prefix:string,i:number)=>prefix+String(i).padStart(4,'0');
const caption=(name:string)=>JSON.stringify({en:{name:'Fallback',title:'Fallback'},zh:{name,title:name,location:'原地点',content:'PRIVATE_LONG_BODY'.repeat(100)}});
test('complete reads use100 bounded summaries and no empty terminal probe',async()=>{
  const calls:number[][]=[];let counts=0;
  const rows=await completeCmsRows({count:async()=>{counts++;return 251;},readBatch:async(skip,take)=>{calls.push([skip,take]);return Array.from({length:Math.min(take,251-skip)},(_,i)=>({id:String(skip+i)}));}});
  assert.equal(rows.length,251);assert.equal(new Set(rows.map(r=>r.id)).size,251);assert.equal(counts,1);assert.deepEqual(calls,[[0,100],[100,100],[200,100]]);
  let reads=0;assert.deepEqual(await completeCmsRows({count:async()=>0,readBatch:async()=>{reads++;return [{id:'unexpected'}];}}),[]);assert.equal(reads,0);
});
test('bad or failed continuation cannot silently publish a partial CMS directory',async()=>{
  await assert.rejects(completeCmsRows({count:async()=>101,readBatch:async skip=>skip?[]:Array.from({length:100},(_,i)=>({id:String(i)}))}),/完整结果/);
  await assert.rejects(completeCmsRows({count:async()=>2,readBatch:async()=>[{id:'same'},{id:'same'}]}),/身份/);
  await assert.rejects(completeCmsRows({count:async()=>101,readBatch:async skip=>{if(skip)throw new Error('controlled read interruption');return Array.from({length:100},(_,i)=>({id:String(i)}));}}),/interruption/);
});
test('summary localization keeps displayed fallback and never edits the original JSON',()=>{
  const original=caption('原名称');assert.deepEqual(JSON.parse(cmsCaptionJson(original,['name','location'])),{zh:{name:'原名称',location:'原地点'}});assert.equal(cmsCaptionJson(original,['name']).includes('PRIVATE_LONG_BODY'),false);assert.equal(original.includes('PRIVATE_LONG_BODY'),true);
});
async function contracts(db:PrismaClient,url:string){
 const old=process.env.DATABASE_URL;process.env.DATABASE_URL=url;
 try{
  const stamp=new Date('2026-10-01T00:00:00Z');
  await db.series.createMany({data:Array.from({length:n},(_,i)=>({id:id('series',i),code:id('series',i),i18n:caption(`系列${i}`),sortOrder:i}))});
  await db.product.createMany({data:Array.from({length:n},(_,i)=>({id:id('product',i),slug:id('product',i),seriesId:id('series',0),i18n:caption(i===0?'Panel AB':`Panel AB ${i}`),sortOrder:i,functionType:i%3===0?null:i%3===1?'other':'legacy-other',published:i!==249}))});
  await db.productVariant.create({data:{id:'last-variant',productId:id('product',249),sku:'EXACT-LAST-SKU',i18n:caption('原款式'),image:'/images/fixture.webp',published:false}});
  await db.product.create({data:{id:'outside-series',slug:'outside-series',seriesId:id('series',1),i18n:caption('Panel AB outside')}});
  const scope={q:'Panel AB',seriesId:id('series',0),functionType:'other',review:''};
  const products=await readCmsProducts(db,scope);assert.equal(products.total,n);assert.equal(products.seriesOptions.length,n);assert.equal(products.products[0].id,id('product',0));assert.equal(products.products.at(-1)?.id,id('product',249));assert.equal(products.products.at(-1)?.published,false);assert.equal(products.products.at(-1)?.variants.length,1);assert.equal(JSON.stringify(products).includes('PRIVATE_LONG_BODY'),false);
  const unsearched=await readCmsProducts(db,{...scope,q:''});assert.deepEqual(unsearched.products.map(row=>row.id),products.products.map(row=>row.id));
  assert.equal((await readCmsProducts(db,{...scope,q:'EXACT-LAST-SKU'})).products[0].id,id('product',249));
  assert.equal((await db.product.findUniqueOrThrow({where:{id:id('product',0)}})).i18n.includes('PRIVATE_LONG_BODY'),true);
  await db.product.update({where:{id:id('product',249)},data:{featured:true}});assert.equal((await readCmsProducts(db,scope)).products[0].id,id('product',249),'fresh requests cannot replay a cached sort');
  await db.product.createMany({data:Array.from({length:251},(_,i)=>({id:id('tied',i),slug:id('tied',i),seriesId:id('series',1),i18n:caption(`原排序${i}`),featured:i%3===0,sortOrder:i%7}))});
  const tied=await readCmsProducts(db,{q:'',seriesId:id('series',1),functionType:'',review:''});
  const expectedTies=await db.product.findMany({where:{seriesId:id('series',1)},orderBy:[{featured:'desc'},{sortOrder:'asc'},{id:'asc'}],select:{id:true}});
  assert.deepEqual(tied.products.map(row=>row.id),expectedTies.map(row=>row.id),'descending featured and repeated sort values must remain complete across cursor batches');
  for(let start=0;start<1251;start+=100)await db.product.createMany({data:Array.from({length:Math.min(100,1251-start)},(_,offset)=>{
    const i=start+offset;return{id:id('rank-window',i),slug:id('rank-window',i),seriesId:id('series',2),featured:i%7===0,sortOrder:i%5,
      model:i===0||i===1?'MIX TOKEN':null,i18n:JSON.stringify({zh:{name:i===1250?'SKU-only identity':i%3===0?`contains Mix token ${i}`:`Mix token ${i}`}})};
  })});
  await db.productVariant.create({data:{productId:id('rank-window',1250),sku:'MIX TOKEN tail',i18n:'{"zh":{"name":"SKU-only"}}',published:false}});
  const rankedScope={q:'mix token',seriesId:id('series',2),functionType:'',review:''};
  const expectedRanked=await productSearchPage(db,{query:'mix token',seriesIds:[id('series',2)],internal:true},0,1251);
  const ranked=await readCmsProducts(db,rankedScope);
  assert.equal(ranked.total,1251);assert.deepEqual(ranked.products.map(row=>row.id),expectedRanked.ids,'all ranked identities must retain exact/prefix/contains/featured/tie order across bounded summary batches');
  assert.ok(ranked.products.some(row=>row.id===id('rank-window',1250)),'an unpublished SKU-only tail match must remain reachable');
  await db.caseItem.createMany({data:Array.from({length:n},(_,i)=>({id:id('case',i),slug:id('case',i),i18n:caption(`案例${i}`),sortOrder:i}))});
  await db.job.createMany({data:Array.from({length:n},(_,i)=>({id:id('job',i),slug:id('job',i),i18n:caption(`岗位${i}`),department:'原部门',location:'原地点',sortOrder:i}))});
  await db.news.createMany({data:Array.from({length:n},(_,i)=>({id:id('news',i),slug:id('news',i),i18n:caption(`文章${i}`),category:'company',publishedAt:stamp}))});
  await db.scenePreset.createMany({data:Array.from({length:n},(_,i)=>({id:id('scene',i),slug:id('scene',i),i18n:caption(`场景${i}`),backgroundImage:'/images/fixture.webp',config:'{"original":"preserved"}',sortOrder:i}))});
  const cases=await readCmsCases(db),jobs=await readCmsJobs(db),news=await readCmsNews(db),series=await readCmsSeries(db),scenes=await readCmsScenes(db);
  for(const rows of[cases,jobs,news,series,scenes]){assert.equal(rows.length,n);assert.equal(new Set(rows.map(r=>r.id)).size,n);assert.equal(JSON.stringify(rows).includes('PRIVATE_LONG_BODY'),false);}
  assert.equal(cases.at(-1)?.id,id('case',249));assert.equal(news.at(-1)?.id,id('news',249));assert.equal(series[0]._count.products,n);assert.equal('config'in scenes[0],false);
  await db.inquiry.createMany({data:Array.from({length:n},(_,i)=>({id:id('inquiry',i),name:`原联系人${i}`,message:`原询盘${i}`,createdAt:stamp}))});
  await db.inquiryDelivery.create({data:{inquiryId:id('inquiry',249),state:'ACKNOWLEDGED',erpInquiryId:'original-erp-identity'}});
  const inquiries=await readCmsInquiries(db);assert.equal(inquiries.length,n);assert.equal(inquiries.at(-1)?.delivery?.erpInquiryId,'original-erp-identity');assert.equal(inquiries.at(-1)?.message,'原询盘249');
  await db.websiteDocumentAsset.create({data:{id:'document-asset',storageKey:'private-original.pdf',originalName:'原件.pdf',sha256:'a'.repeat(64),mimeType:'application/pdf',sizeBytes:100,createdBy:'fixture'}});
  await db.resourceDocument.createMany({data:Array.from({length:n},(_,i)=>({id:id('resource',i),slug:id('resource',i),i18n:caption(`资料${i}`),language:'zh',version:'v1',assetId:'document-asset',published:i%2===0,updatedAt:stamp}))});
  const resources=await readCmsResources(db);assert.equal(resources.length,n);assert.equal(resources.at(-1)?.asset.originalName,'原件.pdf');assert.equal('storageKey'in resources[0].asset,false);
  await db.cmsRevision.createMany({data:Array.from({length:n},(_,i)=>({id:id('revision',i),entityType:i%2===0?'product':'news',operation:'UPDATE',title:`原版本${i}`,payload:'PRIVATE_REVISION_PAYLOAD',beforeState:'PRIVATE_ORIGINAL',status:i<125?'DRAFT':'PUBLISHED',createdBy:'fixture',createdAt:stamp}))});
  const releases=await readCmsReleases(db,['news'],'DRAFT');assert.equal(releases.length,62);assert.equal(releases.every(r=>r.entityType==='news'&&r.status==='DRAFT'),true);assert.equal('payload'in releases[0],false);assert.equal('beforeState'in releases[0],false);
  assert.deepEqual(await readCmsReleases({$transaction:()=>{throw new Error('unnecessary query');}}as unknown as PrismaClient,[]),[]);
  await db.websiteStateAuthority.upsert({where:{id:'production'},update:{authorityUuid:'11111111-1111-4111-8111-111111111111'},create:{id:'production',authorityUuid:'11111111-1111-4111-8111-111111111111'}});
  await db.websiteMediaObject.createMany({data:Array.from({length:n},(_,i)=>({publicPath:`/uploads/fixture-${i}.webp`,authorityId:'production',sha256:'b'.repeat(64),sizeBytes:100,state:'COMMITTED',createdAt:stamp}))});
  await db.websiteMediaObject.create({data:{publicPath:'/uploads/pending.webp',authorityId:'production',sha256:'c'.repeat(64),sizeBytes:100,state:'PENDING'}});
  await db.legacyMediaAsset.createMany({data:Array.from({length:n},(_,i)=>({id:id('legacy',i),sha256:i.toString(16).padStart(64,'0'),mimeType:'image/webp',extension:'.webp',bytes:100,sourcePath:'original-source',publicPath:`/images/legacy-${i}.webp`,sourceUrls:'[]',sourceRefs:'[]'}))});
  await db.legacyMediaAsset.create({data:{id:'no-public-path',sha256:'f'.repeat(64),mimeType:'image/webp',extension:'.webp',bytes:100,sourcePath:'private-original',sourceUrls:'[]',sourceRefs:'[]'}});
  assert.equal((await readCmsMedia(db,false)).length,n);assert.equal((await readCmsMedia(db,true)).length,n);assert.equal((await db.websiteMediaObject.findUniqueOrThrow({where:{publicPath:'/uploads/pending.webp'}})).state,'PENDING');
 }finally{if(old===undefined)delete process.env.DATABASE_URL;else process.env.DATABASE_URL=old;}
}
test('all ten CMS scopes read complete summaries beyond old30/40/200 limits on migrated SQLite',async()=>{const fixture=await migratedDatabase();const db=new PrismaClient({datasources:{db:{url:fixture.databaseUrl}}});try{await contracts(db,fixture.databaseUrl);}finally{await db.$disconnect();await fixture.dispose();}});
test('the same complete scope/caption contract on isolated PostgreSQL',{skip:!postgresqlTestsEnabled()},async()=>{const fixture=await createIsolatedPostgresqlDatabase('c09');try{await contracts(fixture.client as unknown as PrismaClient,fixture.databaseUrl);}finally{await fixture.dispose();}});
