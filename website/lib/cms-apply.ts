import { createHash, randomUUID } from 'node:crypto';
import type { Prisma } from '@prisma/client';
import { localeOrMissing, mergeAdminI18n } from './admin-i18n';
import { getProductPublicationIssue, getSeriesPublicationIssue, publicProductWhere } from './publication';
import { isNewsCategory } from './news-content';
import { isProductClassificationStatus, isProductFunctionType, isSeriesCatalogRole } from './product-taxonomy';
import {
  FormValidationError, PRODUCT_CONTROL_MODES, strictText, optionalImagePath,
  optionalNumber, requiredInteger, parseProductSpecLocale, productSpecsJson,
  parseProductVariants, productVariantData, parseSeriesMedia, seriesMediaData,
  isSettingKey, assertExistingSettingShape, parseSiteSetting,
} from './cms-inputs';

export type CmsEntityType = 'product' | 'series' | 'scene' | 'news' | 'case' | 'job' | 'setting' | 'resource';
export type CmsFormPayload = Record<string, string | string[]>;
export type CmsRow = Record<string, unknown>;
export type CmsSnapshot = {
  record: CmsRow | null;
  variants: CmsRow[];
  media: CmsRow[];
  productMedia: CmsRow[];
  sourceLinks: CmsRow[];
  sceneBindings: CmsRow[];
  scope: { sourceIds: string[]; sceneIds: string[] };
};
export type CmsTx = Prisma.TransactionClient;
export const cmsEntityTypes: readonly CmsEntityType[] = ['product','series','scene','news','case','job','setting','resource'];
export const cmsEditPermission = (type: CmsEntityType) => type === 'product' || type === 'series'
  ? 'website:product_edit' : type === 'resource' ? 'website:media_manage' : 'website:content_edit';

export function formDataToCmsPayload(form: FormData): CmsFormPayload {
  const result: CmsFormPayload = {};
  for (const [key, value] of form.entries()) {
    if (typeof value !== 'string') throw new FormValidationError('请先上传文件，再保存内容草稿');
    if (key.startsWith('$ACTION_')) continue;
    if(['__proto__','constructor','prototype'].includes(key))throw new FormValidationError('草稿字段名称无效');
    const previous = result[key];
    result[key] = previous === undefined ? value : [...(Array.isArray(previous) ? previous : [previous]), value];
  }
  if (JSON.stringify(result).length > 512_000) throw new FormValidationError('草稿内容过大');
  return result;
}
export function cmsPayloadToFormData(payload: CmsFormPayload): FormData {
  const form = new FormData();
  for (const [key, value] of Object.entries(payload)) {
    const values = Array.isArray(value) ? value : [value];
    if (values.some(v => typeof v !== 'string')) throw new FormValidationError('草稿字段格式不正确');
    for (const item of values) form.append(key, item);
  }
  return form;
}
export function cmsSnapshotHash(value: unknown): string {
  const stable = (item: unknown): unknown => item instanceof Date ? item.toISOString()
    : Array.isArray(item) ? item.map(stable)
    : item && typeof item === 'object' ? Object.fromEntries(Object.entries(item).sort(([a],[b]) => a.localeCompare(b)).map(([k,v]) => [k, stable(v)]))
    : item;
  return createHash('sha256').update(JSON.stringify(stable(value))).digest('hex');
}
const json = <T>(value: T): T => JSON.parse(JSON.stringify(value)) as T;
const ids = (rows: CmsRow[]) => rows.map(row => String(row.id)).sort();
const scalar = (row: CmsRow | null, key: string) => typeof row?.[key] === 'string' ? row[key] as string : null;
const conflict = () => new FormValidationError('内容或关联数据已变化，请重新载入并保存新草稿');

export async function readCmsSnapshot(tx: CmsTx, type: CmsEntityType, id: string,
  tracking?: CmsSnapshot['scope']): Promise<CmsSnapshot> {
  let record: object | null;
  switch (type) {
    case 'product': record = await tx.product.findUnique({where:{id}}); break;
    case 'series': record = await tx.series.findUnique({where:{id}}); break;
    case 'scene': record = await tx.scenePreset.findUnique({where:{id}}); break;
    case 'news': record = await tx.news.findUnique({where:{id}}); break;
    case 'case': record = await tx.caseItem.findUnique({where:{id}}); break;
    case 'job': record = await tx.job.findUnique({where:{id}}); break;
    case 'setting': record = await tx.setting.findUnique({where:{key:id}}); break;
    case 'resource': record = await tx.resourceDocument.findUnique({where:{id}}); break;
  }
  const result: CmsSnapshot = {record: record as CmsRow | null, variants:[],media:[],productMedia:[],sourceLinks:[],sceneBindings:[],
    scope:{sourceIds:tracking?.sourceIds ?? [],sceneIds:tracking?.sceneIds ?? []}};
  if (type === 'product') {
    result.variants = await tx.productVariant.findMany({where:{productId:id},orderBy:{id:'asc'}});
    result.productMedia = await tx.productMedia.findMany({where:{productId:id},orderBy:{id:'asc'}});
    const variantIds=ids(result.variants);
    result.sceneBindings=await tx.scenePreset.findMany({where:{OR:[{defaultVariantId:{in:variantIds}},{id:{in:result.scope.sceneIds}}]},
      select:{id:true,defaultVariantId:true,updatedAt:true},orderBy:{id:'asc'}});
    result.sourceLinks=await tx.legacySourceRecord.findMany({where:{OR:[{productId:id},{variantId:{in:variantIds}},{id:{in:result.scope.sourceIds}}]},
      select:{id:true,productId:true,variantId:true,seriesId:true},orderBy:{id:'asc'}});
  } else if(type==='series') {
    result.media=await tx.seriesMedia.findMany({where:{seriesId:id},orderBy:{id:'asc'}});
    result.sourceLinks=await tx.legacySourceRecord.findMany({where:{OR:[{seriesId:id},{id:{in:result.scope.sourceIds}}]},
      select:{id:true,productId:true,variantId:true,seriesId:true},orderBy:{id:'asc'}});
  }
  result.scope={sourceIds:[...new Set([...result.scope.sourceIds,...ids(result.sourceLinks)])].sort(),
    sceneIds:[...new Set([...result.scope.sceneIds,...ids(result.sceneBindings)])].sort()};
  return json(result);
}

function baseRow(before: CmsSnapshot, id: string, extra: CmsRow = {}): CmsRow {
  const now=new Date().toISOString();
  return before.record ? {...before.record} : {id,createdAt:now,updatedAt:now,...extra};
}
function preserveIdentity(before: CmsRow | undefined, id: string, values: CmsRow): CmsRow {
  const now=new Date().toISOString();
  return {...(before ?? {id,createdAt:now,updatedAt:now}),...values,id};
}

/** Prepare a deterministic snapshot without any public-table writes. */
export async function prepareCmsSnapshot(tx:CmsTx,type:CmsEntityType,id:string,
  operation:'UPSERT'|'DELETE',payload:CmsFormPayload,before:CmsSnapshot):Promise<CmsSnapshot> {
  const after=json(before);
  if(operation==='DELETE') {
    if(!before.record) throw new FormValidationError('内容不存在');
    after.record=null;after.variants=[];after.media=[];after.productMedia=[];
    after.sceneBindings=after.sceneBindings.map(row=>({...row,defaultVariantId:null}));
    after.sourceLinks=after.sourceLinks.map(row=>({...row,
      ...(type==='product'?{productId:null,variantId:null}:type==='series'?{seriesId:null}:{}),}));
    await assertCmsPublication(tx,type,id,after,before);
    return after;
  }
  const f=cmsPayloadToFormData(payload);
  const text=(name:string,label:string,max=500)=>strictText(f.get(name),label,max);
  const published=f.get('published')==='on';
  const old=before.record;
  if(type==='product') {
    const zhName=text('zh_name','产品中文名称',160);
    if(!zhName) throw new FormValidationError('请填写产品中文名称');
    const functionType=text('functionType','功能类型',60)||null;
    if(functionType&&!isProductFunctionType(functionType))throw new FormValidationError('功能类型无效');
    const controlMode=text('controlMode','控制方式',40)||null;
    if(controlMode&&!(PRODUCT_CONTROL_MODES as readonly string[]).includes(controlMode))throw new FormValidationError('控制方式无效');
    const classificationStatus=text('classificationStatus','分类审核状态',40)||'NEEDS_REVIEW';
    if(!isProductClassificationStatus(classificationStatus))throw new FormValidationError('分类审核状态无效');
    const seriesCode=text('seriesCode','系列',80);
    const series=seriesCode?await tx.series.findUnique({where:{code:seriesCode}}):null;
    if(seriesCode&&!series)throw new FormValidationError('所选产品系列不存在');
    const variants=parseProductVariants(f);
    const oldById=new Map(before.variants.map(v=>[String(v.id),v]));
    if(variants.some(v=>v.id&&!oldById.has(v.id)))throw conflict();
    after.variants=variants.map(v=>preserveIdentity(v.id?oldById.get(v.id):undefined,v.id??randomUUID(),{
      ...productVariantData(v,v.id?scalar(oldById.get(v.id)??null,'i18n'):null),productId:id,
    })).sort((a,b)=>String(a.id).localeCompare(String(b.id)));
    const displayable=variants.filter(v=>v.published&&v.image);
    after.record={...baseRow(before,id,{slug:`p-${id}`,rowVersion:1,gallery:null,sourceIdentity:null,legacySource:null,legacyId:null}),
      seriesId:series?.id??null,model:text('model','型号',120)||null,category:text('category','分类',120)||null,
      functionType,controlMode,gangCount:optionalNumber(f.get('gangCount'),'联数',{min:1,max:12,integer:true}),
      configuration:text('configuration','配置说明',1000)||null,classificationStatus,
      image:optionalImagePath(f.get('image'),'主图')||displayable[0]?.image||null,
      minOrderQty:optionalNumber(f.get('minOrderQty'),'最小起订量',{min:1,integer:true}),
      sceneEnabled:f.get('sceneEnabled')==='on',featured:f.get('featured')==='on',published,
      sortOrder:requiredInteger(f.get('sortOrder'),'产品排序'),
      i18n:mergeAdminI18n(scalar(old,'i18n'),{zh:{name:zhName,description:text('zh_desc','中文描述',5000)},
        en:localeOrMissing({name:text('en_name','英文名称',160),description:text('en_desc','英文描述',5000)})}),
      specs:productSpecsJson(scalar(old,'specs'),parseProductSpecLocale(f,'zh','中文'),parseProductSpecLocale(f,'en','英文')),
    };
    const availableIds=new Set(after.variants.filter(v=>published&&after.record?.sceneEnabled&&v.published&&v.image).map(v=>v.id));
    const keptIds=new Set(ids(after.variants));
    after.sceneBindings=after.sceneBindings.map(v=>({...v,defaultVariantId:availableIds.has(v.defaultVariantId)?v.defaultVariantId:null}));
    after.sourceLinks=after.sourceLinks.map(v=>({...v,variantId:v.variantId&&!keptIds.has(String(v.variantId))?null:v.variantId}));
    after.productMedia=after.productMedia.map(v=>({...v,variantId:v.variantId&&!keptIds.has(String(v.variantId))?null:v.variantId}));
  } else if(type==='series') {
    const code=text('code','系列网址代号',80),publicSlug=text('publicSlug','公开聚合网址',80)||null;
    const catalogRole=text('catalogRole','目录角色',40)||'UNCLASSIFIED';
    if(!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(code)||publicSlug&&!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(publicSlug))throw new FormValidationError('系列网址代号格式无效');
    if(!isSeriesCatalogRole(catalogRole))throw new FormValidationError('目录角色无效');
    const zhName=text('zh_name','系列中文名称',160);
    if(!zhName)throw new FormValidationError('请填写系列中文名称');
    const media=parseSeriesMedia(f),oldById=new Map(before.media.map(v=>[String(v.id),v]));
    if(media.some(v=>v.id&&!oldById.has(v.id)))throw conflict();
    after.media=media.map(v=>preserveIdentity(v.id?oldById.get(v.id):undefined,v.id??randomUUID(),{
      ...seriesMediaData(v,v.id?scalar(oldById.get(v.id)??null,'i18n'):null),seriesId:id,
    })).sort((a,b)=>String(a.id).localeCompare(String(b.id)));
    after.record={...baseRow(before,id,{rowVersion:1,sourceIdentity:null,legacySource:null,legacyId:null}),
      code,publicSlug,catalogRole,parentId:text('parentId','上级系列',80)||null,published,
      coverImage:optionalImagePath(f.get('coverImage'),'系列封面'),sortOrder:requiredInteger(f.get('sortOrder'),'系列排序'),
      i18n:mergeAdminI18n(scalar(old,'i18n'),{zh:{name:zhName,subtitle:text('zh_subtitle','中文副标题',240),description:text('zh_desc','中文描述',5000)},
        en:localeOrMissing({name:text('en_name','英文名称',160),subtitle:text('en_subtitle','英文副标题',240),description:text('en_desc','英文描述',5000)})}),
    };
  } else if(type==='scene') {
    const slug=text('slug','场景网址',120).toLowerCase(),name=text('zh_name','场景名称',160);
    if(!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug)||!name)throw new FormValidationError('请填写有效的场景网址与名称');
    const image=optionalImagePath(f.get('backgroundImage'),'场景背景图');
    if(!image)throw new FormValidationError('请选择场景背景图');
    after.record={...baseRow(before,id),slug,backgroundImage:image,published,sortOrder:requiredInteger(f.get('sortOrder'),'场景排序'),
      defaultVariantId:text('defaultVariantId','默认款式',80)||null,
      config:JSON.stringify({schemaVersion:1,placement:{x:optionalNumber(f.get('positionX'),'水平位置',{min:0,max:100})??50,
        y:optionalNumber(f.get('positionY'),'垂直位置',{min:0,max:100})??50,scale:optionalNumber(f.get('scale'),'缩放',{min:0.1,max:4})??1,
        rotation:optionalNumber(f.get('rotation'),'旋转',{min:-180,max:180})??0}}),
      i18n:mergeAdminI18n(scalar(old,'i18n'),{zh:{name,description:text('zh_description','中文描述',2000)},
        en:localeOrMissing({name:text('en_name','英文名称',160),description:text('en_description','英文描述',2000)})}),
    };
  } else if(type==='setting') {
    if(!isSettingKey(id))throw new FormValidationError('站点设置栏目无效');
    assertExistingSettingShape(id,scalar(old,'i18n'));
    after.record={id:old?.id??randomUUID(),key:id,i18n:mergeAdminI18n(scalar(old,'i18n'),parseSiteSetting(f,id))};
  } else {
    const title=text('zh_title','中文标题',200);
    if(!title)throw new FormValidationError('请填写中文标题');
    const locales:Record<string,Record<string,string>|null>={zh:{title},en:{title:text('en_title','英文标题',200)}};
    const fields=type==='news'?['summary','content']:type==='case'?['location','content']:
      type==='job'?['requirements','description']:['description'];
    for(const locale of ['zh','en'])for(const field of fields) {
      locales[locale]![field]=text(`${locale}_${field}`,`${locale} ${field}`,field==='content'?50_000:10_000);
    }
    locales.en=localeOrMissing(locales.en!);
    const row:CmsRow={...baseRow(before,id,{slug:`${type}-${id}`,sortOrder:0}),i18n:mergeAdminI18n(scalar(old,'i18n'),locales),
      published:f.has('published')?published:(old?.published??true)};
    if(type==='news') {
      delete row.sortOrder;
      const category=text('category','新闻分类',40)||'company';
      if(!isNewsCategory(category))throw new FormValidationError('新闻分类无效');
      const date=text('publishedAt','新闻日期',80);
      const publishedAt=date?new Date(date):new Date();
      if(!Number.isFinite(publishedAt.getTime()))throw new FormValidationError('新闻日期无效');
      after.record={...row,category,coverImage:optionalImagePath(f.get('coverImage'),'新闻封面'),publishedAt:publishedAt.toISOString()};
    } else if(type==='case') after.record={...row,coverImage:optionalImagePath(f.get('coverImage'),'案例封面')};
    else if(type==='job') after.record={...row,department:text('department','部门',160)||null,location:text('location','工作地点',240)||null};
    else {
      delete row.sortOrder;
      const language=text('language','资料语言',20),version=text('version','资料版本',80),assetId=text('assetId','资料文件',100);
      if(!language||!version||!assetId)throw new FormValidationError('资料语言、版本和文件不能为空');
      after.record={...row,rowVersion:old?.rowVersion??1,language,version,assetId,market:text('market','适用市场',120)||null,
        seriesId:text('seriesId','关联系列',100)||null,productId:text('productId','关联产品',100)||null,published};
    }
  }
  await assertCmsPublication(tx,type,id,after,before);
  return json(after);
}

/** Re-check mutable dependencies when publishing or restoring a historical version. */
export async function assertCmsPublication(tx:CmsTx,type:CmsEntityType,id:string,next:CmsSnapshot,current:CmsSnapshot,restoring=false):Promise<void> {
  const row=next.record;
  if(row&&(type==='setting'?row.key!==id:row.id!==id))throw new FormValidationError('版本中的内容稳定标识不一致');
  if(type==='product'&&(next.variants.some(v=>v.productId!==id)||new Set(ids(next.variants)).size!==next.variants.length))
    throw new FormValidationError('版本中的产品款式归属或标识不一致');
  if(type==='series'&&(next.media.some(v=>v.seriesId!==id)||new Set(ids(next.media)).size!==next.media.length))
    throw new FormValidationError('版本中的系列素材归属或标识不一致');
  if(!row) {
    if(!restoring&&(type==='product'||type==='series')&&current.record?.published)throw new FormValidationError('请先发布下架版本，再删除内容');
    if(type==='series') {
      if(await tx.product.count({where:{seriesId:id}})||await tx.series.count({where:{parentId:id}})||await tx.resourceDocument.count({where:{seriesId:id}}))
        throw new FormValidationError('系列仍有关联产品、子系列或资料，不能删除');
    }
    if(type==='product'&&await tx.resourceDocument.count({where:{productId:id}}))throw new FormValidationError('产品仍有关联资料，不能删除');
    return;
  }
  if(type==='product') {
    const series=row.seriesId?await tx.series.findUnique({where:{id:String(row.seriesId)},include:{parent:true}}):null;
    if(row.seriesId&&!series)throw new FormValidationError('关联系列不存在');
    if(getProductPublicationIssue(row.published===true,series))throw new FormValidationError('产品发布需要有效且已发布的系列及 FAMILY 上级');
    const visible=next.variants.filter(v=>v.published&&v.image);
    if((row.published||row.sceneEnabled)&&!visible.length)throw new FormValidationError('发布或试装至少需要一个已发布且有正面图的款式');
    if(row.published&&!visible.some(v=>v.isDefault))throw new FormValidationError('发布产品前请选择可展示的默认款式');
    const skus=next.variants.flatMap(v=>v.sku?[String(v.sku).normalize('NFKC').toLowerCase()]:[]);
    if(new Set(skus).size!==skus.length)throw new FormValidationError('产品款式 SKU 重复');
    if(skus.length) {
      const others=await tx.productVariant.findMany({where:{productId:{not:id},sku:{not:null}},select:{sku:true}});
      if(others.some(v=>v.sku&&skus.includes(v.sku.normalize('NFKC').toLowerCase())))throw new FormValidationError('SKU 已被其他产品使用');
    }
    if(next.variants.some(v=>v.legacySynthetic&&(v.sku||v.dataStatus==='VERIFIED')))throw new FormValidationError('历史合成款式不得冒充真实 SKU 或已核验数据');
  } else if(type==='series') {
    const parentId=scalar(row,'parentId');let selectedParent=null;
    const visited=new Set<string>([id]);let cursor=parentId;
    while(cursor) {
      if(visited.has(cursor))throw new FormValidationError('系列层级不能形成循环');visited.add(cursor);
      const parent=await tx.series.findUnique({where:{id:cursor}});
      if(!parent)throw new FormValidationError('上级系列不存在');if(cursor===parentId)selectedParent=parent;cursor=parent.parentId;
    }
    const issue=getSeriesPublicationIssue(row.published===true,String(row.catalogRole),selectedParent,{
      publishedProducts:await tx.product.count({where:{seriesId:id,published:true}}),
      publishedCollections:await tx.series.count({where:{parentId:id,published:true,catalogRole:'COLLECTION'}}),
    });
    if(issue||row.published&&['CONTAINER','ARCHIVE'].includes(String(row.catalogRole)))throw new FormValidationError('当前系列或其公开下级不满足发布层级要求');
    if(await tx.series.findFirst({where:{id:{not:id},OR:[{code:String(row.code)},...(row.publicSlug?[{publicSlug:String(row.publicSlug)}]:[])]}}))throw new FormValidationError('系列网址已被使用');
  } else if(type==='scene'&&row.defaultVariantId) {
    const variant=await tx.productVariant.findUnique({where:{id:String(row.defaultVariantId)},include:{product:{include:{series:{include:{parent:true}}}}}});
    if(!variant||!variant.image||!variant.product.sceneEnabled||row.published&&(!variant.published||!variant.product.published||getProductPublicationIssue(true,variant.product.series)))
      throw new FormValidationError('默认款式或其产品系列不可用于公开场景');
  } else if(type==='resource') {
    if(!await tx.websiteDocumentAsset.findUnique({where:{id:String(row.assetId)}}))throw new FormValidationError('资料文件不存在');
    if(row.productId) {
      const product=await tx.product.findFirst({where:row.published?publicProductWhere({id:String(row.productId)}):{id:String(row.productId)}});
      if(!product||row.seriesId&&row.seriesId!==product.seriesId)throw new FormValidationError('资料的关联产品与系列不匹配或尚未公开');
    }
    if(row.seriesId) {
      const series=await tx.series.findUnique({where:{id:String(row.seriesId)},include:{parent:true}});
      if(!series||row.published&&getProductPublicationIssue(true,series))throw new FormValidationError('资料关联系列尚未公开');
    }
  } else if(type==='setting'&&row.key==='hero') {
    const content=JSON.parse(String(row.i18n)) as Record<string,Record<string,unknown>>;
    for(const value of Object.values(content)) {
      if(value.heroImage)optionalImagePath(String(value.heroImage),'首页展示图');
      if(value.heroSeriesId) {
        const series=await tx.series.findUnique({where:{id:String(value.heroSeriesId)},include:{parent:true}});
        if(!series||getProductPublicationIssue(true,series))throw new FormValidationError('首页展示系列必须有效且已公开');
      }
    }
  }
}

/** The only public-content write boundary. Caller must own a verified revision transaction. */
export async function applyCmsSnapshot(tx:CmsTx,type:CmsEntityType,id:string,
  target:CmsSnapshot,current:CmsSnapshot,restoring=false):Promise<void> {
  await assertCmsPublication(tx,type,id,target,current,restoring);
  if(!target.record) {
    switch(type) {
      case 'product': await tx.product.delete({where:{id}}); break;
      case 'series': await tx.series.delete({where:{id}}); break;
      case 'scene': await tx.scenePreset.delete({where:{id}}); break;
      case 'news': await tx.news.delete({where:{id}}); break;
      case 'case': await tx.caseItem.delete({where:{id}}); break;
      case 'job': await tx.job.delete({where:{id}}); break;
      case 'setting': await tx.setting.delete({where:{key:id}}); break;
      case 'resource': await tx.resourceDocument.delete({where:{id}}); break;
    }
  } else {
    const data={...target.record};
    if(type!=='setting')data.updatedAt=new Date();
    if(['product','series','resource'].includes(type))data.rowVersion=Number(current.record?.rowVersion??0)+1;
    switch(type) {
      case 'product': {
        const typed=data as unknown as Prisma.ProductUncheckedCreateInput;
        if(current.record) {
          if((await tx.product.updateMany({where:{id,rowVersion:Number(current.record.rowVersion)},data:typed})).count!==1)throw conflict();
        } else await tx.product.create({data:typed});
        const retained=ids(target.variants);
        await tx.productVariant.deleteMany({where:{productId:id,id:{notIn:retained}}});
        for(const row of target.variants) {
          const existing=await tx.productVariant.findUnique({where:{id:String(row.id)},select:{productId:true}});
          if(existing&&existing.productId!==id)throw conflict();
          const typedVariant={...row,updatedAt:new Date()} as unknown as Prisma.ProductVariantUncheckedCreateInput;
          await tx.productVariant.upsert({where:{id:String(row.id)},create:typedVariant,update:typedVariant});
        }
        await tx.productMedia.deleteMany({where:{productId:id,id:{notIn:ids(target.productMedia)}}});
        for(const row of target.productMedia) {
          const existing=await tx.productMedia.findUnique({where:{id:String(row.id)},select:{productId:true}});
          if(existing&&existing.productId!==id)throw conflict();
          const typedMedia=row as unknown as Prisma.ProductMediaUncheckedCreateInput;
          await tx.productMedia.upsert({where:{id:String(row.id)},create:typedMedia,update:typedMedia});
        }
        break;
      }
      case 'series': {
        const typed=data as unknown as Prisma.SeriesUncheckedCreateInput;
        if(current.record) {
          if((await tx.series.updateMany({where:{id,rowVersion:Number(current.record.rowVersion)},data:typed})).count!==1)throw conflict();
        } else await tx.series.create({data:typed});
        await tx.seriesMedia.deleteMany({where:{seriesId:id,id:{notIn:ids(target.media)}}});
        for(const row of target.media) {
          const existing=await tx.seriesMedia.findUnique({where:{id:String(row.id)},select:{seriesId:true}});
          if(existing&&existing.seriesId!==id)throw conflict();
          const typedMedia={...row,updatedAt:new Date()} as unknown as Prisma.SeriesMediaUncheckedCreateInput;
          await tx.seriesMedia.upsert({where:{id:String(row.id)},create:typedMedia,update:typedMedia});
        }
        break;
      }
      case 'scene': {const d=data as unknown as Prisma.ScenePresetUncheckedCreateInput;
        if(current.record){if((await tx.scenePreset.updateMany({where:{id,updatedAt:new Date(String(current.record.updatedAt))},data:d})).count!==1)throw conflict();}
        else await tx.scenePreset.create({data:d});break;}
      case 'news': {const d=data as unknown as Prisma.NewsUncheckedCreateInput;
        if(current.record){if((await tx.news.updateMany({where:{id,updatedAt:new Date(String(current.record.updatedAt))},data:d})).count!==1)throw conflict();}
        else await tx.news.create({data:d});break;}
      case 'case': {const d=data as unknown as Prisma.CaseItemUncheckedCreateInput;
        if(current.record){if((await tx.caseItem.updateMany({where:{id,updatedAt:new Date(String(current.record.updatedAt))},data:d})).count!==1)throw conflict();}
        else await tx.caseItem.create({data:d});break;}
      case 'job': {const d=data as unknown as Prisma.JobUncheckedCreateInput;
        if(current.record){if((await tx.job.updateMany({where:{id,updatedAt:new Date(String(current.record.updatedAt))},data:d})).count!==1)throw conflict();}
        else await tx.job.create({data:d});break;}
      case 'setting': {const d=data as unknown as Prisma.SettingUncheckedCreateInput;
        if(current.record){if((await tx.setting.updateMany({where:{key:id,i18n:String(current.record.i18n)},data:d})).count!==1)throw conflict();}
        else await tx.setting.create({data:d});break;}
      case 'resource': {const d=data as unknown as Prisma.ResourceDocumentUncheckedCreateInput;
        if(current.record){if((await tx.resourceDocument.updateMany({where:{id,rowVersion:Number(current.record.rowVersion)},data:d})).count!==1)throw conflict();}
        else await tx.resourceDocument.create({data:d});break;}
    }
  }
  // Restore only relationships this entity owns; never overwrite a source payload or scene body.
  for(const row of target.sourceLinks)await tx.legacySourceRecord.update({where:{id:String(row.id)},data:{
    productId:scalar(row,'productId'),variantId:scalar(row,'variantId'),seriesId:scalar(row,'seriesId')}});
  for(const row of target.sceneBindings) {
    const prior=current.sceneBindings.find(v=>v.id===row.id);
    if(prior?.defaultVariantId!==row.defaultVariantId)
      await tx.scenePreset.update({where:{id:String(row.id)},data:{defaultVariantId:scalar(row,'defaultVariantId')}});
  }
}
