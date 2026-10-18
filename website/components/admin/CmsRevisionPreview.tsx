import Image from 'next/image';
import type { CmsSnapshot, CmsRow } from '@/lib/cms-apply';

const labels:Record<string,string>={title:'标题',name:'名称',description:'说明',subtitle:'副标题',content:'正文',summary:'摘要',
  image:'主图',coverImage:'封面图片',backgroundImage:'场景背景',heroImage:'首页展示图',heroSeriesId:'首页展示系列',
  model:'型号',category:'分类',functionType:'功能类型',gangCount:'联数',controlMode:'控制方式',configuration:'配置说明',
  published:'公开展示',featured:'首页精选',sceneEnabled:'启用试装',sortOrder:'排序',sku:'SKU',finish:'表面处理',
  widthMm:'宽度 (mm)',heightMm:'高度 (mm)',depthMm:'厚度 (mm)',swatchHex:'色卡',dataStatus:'资料核验状态',
  classificationStatus:'分类核验状态',legacySynthetic:'历史合成占位',isDefault:'默认款式',minOrderQty:'最小起订量',
  code:'系列网址',publicSlug:'公开网址',catalogRole:'目录角色',parentId:'上级系列',seriesId:'关联系列',productId:'关联产品',
  key:'栏目',id:'稳定标识',sourceIdentity:'来源标识',legacySource:'历史来源',legacyId:'历史来源编号',
  phone:'电话',phone2:'备用电话',email:'邮箱',address:'地址',company:'公司',icp:'备案号',
  cta:'按钮',cta1:'主要按钮',cta2:'次要按钮',language:'语言',version:'资料版本',market:'适用市场',assetId:'资料文件标识',
  location:'地点',department:'部门',requirements:'任职要求',publishedAt:'内容日期',role:'素材用途',alt:'替代文字',
  createdAt:'创建时间',updatedAt:'更新时间',rowVersion:'记录版本',zh:'中文',en:'English'};
const readJson=(value:unknown):unknown=>{if(typeof value!=='string')return value;try{return JSON.parse(value);}catch{return value;}};
function locale(row:CmsRow|null):Record<string,unknown>{
  const all=readJson(row?.i18n);
  if(!all||typeof all!=='object'||Array.isArray(all))return {};
  const values=all as Record<string,unknown>;
  const preferred=values.zh??values.en;
  return preferred&&typeof preferred==='object'&&!Array.isArray(preferred)?preferred as Record<string,unknown>:{};
}
const title=(row:CmsRow|null)=>String(locale(row).title??locale(row).name??row?.model??row?.code??row?.key??'内容');
const imagePath=(value:unknown)=>typeof value==='string'&&/^\/(?:uploads|images)\/[^\s?#\\]+$/.test(value)&&!value.split('/').includes('..')?value:null;

function flatten(value:unknown,path:string,result:Map<string,string>) {
  const parsed=['i18n','specs','gallery','config'].some(key=>path===key||path.endsWith(` / ${key}`))?readJson(value):value;
  if(parsed&&typeof parsed==='object') {
    for(const [key,item] of Object.entries(parsed))flatten(item,`${path}${path?' / ':''}${labels[key]??key}`,result);
    return;
  }
  result.set(path,parsed===null||parsed===undefined||parsed===''?'未填写':typeof parsed==='boolean'?(parsed?'是':'否'):String(parsed));
}
function fields(snapshot:CmsSnapshot):Map<string,string>{
  const result=new Map<string,string>();
  if(snapshot.record) {
    const visible={...snapshot.record};delete visible.createdAt;delete visible.updatedAt;delete visible.rowVersion;
    flatten(visible,'',result);
  }
  for(const [section,rows] of [['款式',snapshot.variants],['系列素材',snapshot.media],['来源图库',snapshot.productMedia],
    ['来源关联',snapshot.sourceLinks],['场景关联',snapshot.sceneBindings]] as const) {
    for(const row of rows) {
      const visible={...row};delete visible.createdAt;delete visible.updatedAt;
      flatten(visible,`${section} ${row.id}`,result);
    }
  }
  return result;
}
function DifferenceTable({rows}:{rows:{key:string;before:string;after:string}[]}) {
  return <div className="overflow-x-auto"><table className="w-full min-w-[560px] text-left text-sm">
    <thead><tr className="border-b border-border text-muted-foreground"><th className="p-3">变更字段</th><th className="p-3">保存草稿时</th><th className="p-3">此版本</th></tr></thead>
    <tbody>{rows.map(row=><tr key={row.key} className="border-b border-border align-top"><th className="max-w-64 break-words p-3 font-medium">{row.key}</th>
      <td className="max-w-md whitespace-pre-wrap break-words p-3 text-muted-foreground">{row.before}</td>
      <td className="max-w-md whitespace-pre-wrap break-words p-3">{row.after}</td></tr>)}</tbody>
  </table></div>;
}
export function CmsRevisionPreview({before,after}:{before:CmsSnapshot;after:CmsSnapshot}) {
  const record=after.record??before.record,content=locale(record);
  const image=imagePath(record?.image??record?.coverImage??record?.backgroundImage??content.heroImage);
  const previous=fields(before),next=fields(after);
  const differences=[...new Set([...previous.keys(),...next.keys()])].filter(k=>previous.get(k)!==next.get(k))
    .map(key=>({key,before:previous.get(key)??'不存在',after:next.get(key)??'移除'}));
  return <div className="space-y-7">
    {!after.record&&<p className="rounded-xl border border-destructive/30 bg-destructive/5 p-4 text-destructive">这是删除版本。发布后将移除下列内容，原始版本与来源关联保留在发布记录中。</p>}
    <section aria-label="此版本内容预览" className="card-uten grid gap-7 p-5 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)] lg:p-8">
      {image&&<div className="flex min-h-52 items-center justify-center rounded-xl bg-muted/40 p-6"><Image src={image} alt={title(record)} width={800} height={600} className="max-h-80 w-full object-contain" unoptimized /></div>}
      <div className={image?'':'lg:col-span-2'}>
        <h2 className="font-heading text-2xl font-semibold">{title(record)}</h2>
        {Boolean(content.subtitle)&&<p className="mt-3 text-lg text-muted-foreground">{String(content.subtitle)}</p>}
        {['description','summary','content','body','requirements','intro'].map(key=>content[key]?
          <div key={key} className="mt-4 whitespace-pre-wrap leading-7">{String(content[key])}</div>:null)}
        {Boolean(record?.model)&&<p className="mt-4 text-sm">型号：{String(record?.model)}</p>}
        {typeof record?.published==='boolean'&&<p className="mt-4 text-sm text-muted-foreground">发布后展示状态：{record.published?'公开展示':'不公开展示'}</p>}
      </div>
      {after.variants.length>0&&<div className="lg:col-span-2"><h3 className="mb-3 font-semibold">此版本的产品款式</h3>
        <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">{[...after.variants].sort((a,b)=>Number(a.sortOrder)-Number(b.sortOrder)).map(variant=>{
          const src=imagePath(variant.image);return <div key={String(variant.id)} className="rounded-xl border border-border p-4">
            {src&&<Image src={src} alt={title(variant)} width={320} height={240} className="mb-3 h-40 w-full object-contain" unoptimized />}
            <p className="font-medium">{title(variant)}</p><p className="mt-1 text-sm text-muted-foreground">{variant.sku?`SKU：${variant.sku}`:'SKU 未填写'}</p>
            <p className="mt-1 text-sm">{variant.published?'公开款式':'不公开'}{variant.isDefault?'，默认款式':''}</p>
          </div>;
        })}</div>
      </div>}
    </section>
    <section aria-label="版本变更"><h2 className="mb-3 text-lg font-semibold">变更内容 ({differences.length})</h2>
      {differences.length?<DifferenceTable rows={differences.slice(0,60)} />:<p className="text-muted-foreground">没有内容差异。</p>}
      {differences.length>60&&<details className="mt-4"><summary className="cursor-pointer text-accent">展开其余 {differences.length-60} 项变更</summary><DifferenceTable rows={differences.slice(60)} /></details>}
    </section>
  </div>;
}
