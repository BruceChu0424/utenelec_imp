import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { spawn, execFileSync, type ChildProcess } from 'node:child_process';
import http from 'node:http';
import net from 'node:net';
import { mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import fs from 'node:fs';
import path from 'node:path';
import { PrismaClient } from '@prisma/client';
import { migratedDatabase, websiteRoot } from '../tests/helpers/migrated-database';
import { createSessionToken, hashPassword } from '../lib/auth';
import { requireStrongAuthSecret } from '../lib/auth-secret';

async function main(){
const sleep=(ms:number)=>new Promise(resolve=>setTimeout(resolve,ms));
const production=process.argv.includes('--production');
const targetedBuild=process.argv.includes('--targeted-build');
const windowsDebugPaths=targetedBuild&&process.platform==='win32';
const physicalDependencies=process.argv.includes('--physical-dependencies');
const isolatedBuildProfile=process.argv.includes('--isolated-build-profile');
const evidence=path.resolve(websiteRoot,production?(isolatedBuildProfile?'../build/loading-cms/browser-production-isolated-profile':physicalDependencies?'../build/loading-cms/browser-production-physical':targetedBuild?'../build/loading-cms/browser-production-targeted-winpaths':'../build/loading-cms/browser-production'):'../build/loading-cms/browser');await mkdir(evidence,{recursive:true});
const buildFixture=production?await migratedDatabase():undefined;
const fixture=await migratedDatabase();const db=new PrismaClient({datasources:{db:{url:fixture.databaseUrl}}});
let secret='';for(let attempt=0;attempt<100&&!secret;attempt++){try{secret=requireStrongAuthSecret(randomBytes(48).toString('base64url'));}catch{}}
assert.ok(secret,'The ephemeral fixture secret must pass the unchanged production validator');process.env.AUTH_SECRET=secret;
const password=randomBytes(32).toString('hex'),username='cms-loading-task-only';
let next:ChildProcess|undefined,browser:ChildProcess|undefined,socket:WebSocket|undefined;
let token='';let dropNextAction:false|'preheaders'|'body'=false;let actions=0,dropped=0;const metrics:Record<string,unknown>[]=[];let diagnosticStage='initial';let inspectBrowser:(()=>Promise<unknown>)|undefined;let releaseUnknownResponse:(()=>void)|undefined;const proxyRequests={lists:0,details:0,actions:0};
const nextLog=fs.createWriteStream(path.join(evidence,'next-runtime.log'));
const redact=(text:string)=>{const value=text.replaceAll(secret,'[redacted]').replaceAll(password,'[redacted]');return token?value.replaceAll(token,'[redacted]'):value;};
const freePort=()=>new Promise<number>((resolve,reject)=>{const server=net.createServer();server.once('error',reject);server.listen(0,'127.0.0.1',()=>{const port=(server.address()as net.AddressInfo).port;server.close(()=>resolve(port));});});
const nextPort=await freePort();
const proxy=http.createServer((request,response)=>{
  const url=new URL(request.url||'/','http://127.0.0.1');
  if(request.method==='GET'&&url.pathname==='/admin/products')proxyRequests.lists++;
  if(request.method==='GET'&&url.pathname.startsWith('/admin/products/edit/'))proxyRequests.details++;
  const action=request.method==='POST'&&typeof request.headers['next-action']==='string';
  if(action){actions++;proxyRequests.actions++;}
  const upstream=http.request({hostname:'127.0.0.1',port:nextPort,path:request.url,method:request.method,headers:request.headers},source=>{
    if(action&&dropNextAction){const loss=dropNextAction;dropNextAction=false;if(loss==='body'){response.writeHead(source.statusCode||200,source.headers);response.flushHeaders();}source.resume();source.on('end',()=>{releaseUnknownResponse=()=>{dropped++;response.destroy();};});return;}
    response.writeHead(source.statusCode||502,source.headers);source.pipe(response);
  });
  upstream.on('error',()=>{if(!response.headersSent)response.writeHead(502);response.end();});request.pipe(upstream);
});
await new Promise<void>(resolve=>proxy.listen(0,'127.0.0.1',resolve));const proxyPort=(proxy.address()as net.AddressInfo).port;const origin=`http://127.0.0.1:${proxyPort}`;
const profile=path.join(evidence,`cms-headless-${randomUUID()}`);await mkdir(profile);
async function stop(child:ChildProcess|undefined){if(!child||child.exitCode!==null)return;try{if(process.platform==='win32')execFileSync('taskkill',['/PID',String(child.pid),'/T','/F'],{windowsHide:true,stdio:'ignore'});else child.kill('SIGTERM');}catch{}await Promise.race([new Promise<void>(resolve=>child.once('exit',()=>resolve())),sleep(3000)]);}
try{
  await db.user.create({data:{username,password:await hashPassword(password)}});
  await db.series.createMany({data:[{id:'benchmark-first-half',code:'benchmark-first-half',i18n:'{"zh":{"name":"连续列表5000测试"}}',published:false},{id:'benchmark-second-half',code:'benchmark-second-half',i18n:'{"zh":{"name":"连续列表另一半"}}',published:false}]});
  for(let start=0;start<10000;start+=100){await db.product.createMany({data:Array.from({length:100},(_,offset)=>{const index=start+offset;return{id:`cms-load-${String(index).padStart(6,'0')}`,slug:`cms-load-${index}`,seriesId:index<5000?'benchmark-first-half':'benchmark-second-half',i18n:JSON.stringify({zh:{name:`连续列表测试产品${index}`,description:'UNVERIFIED_LOADING_FIXTURE_BODY'.repeat(20)}}),model:`MODEL-${index}`,sortOrder:index,published:false};})});}
  const enginePaths=['node_modules/.prisma/client/query_engine-windows.dll.node','generated/postgresql/query_engine-windows.dll.node'].map(file=>fs.realpathSync(path.join(websiteRoot,file)));
  for(const file of enginePaths)assert.ok(file.startsWith(websiteRoot+path.sep),'Prisma engines must resolve inside this task website');
  const loadedEngines=(process.report.getReport()as unknown as{sharedObjects:string[]}).sharedObjects.filter(file=>file.includes('query_engine'));
  await writeFile(path.join(evidence,'task-engine-paths.json'),JSON.stringify({resolved:enginePaths,loadedBySQLiteFixture:loadedEngines,postgresQueries:'Separate current-lock47-case suite exercises generated PostgreSQL engine'},null,2));
  for(const file of loadedEngines)assert.ok(fs.realpathSync(file).replace(/^\\\\\?\\/,'').toLowerCase().startsWith((websiteRoot+path.sep).toLowerCase()),'Loaded Prisma engine must stay in this task website');
  console.log('Seeded isolated10000-product fixture; no live database used.');
  const preload=path.join(evidence,'prisma-read-probe.cjs');const dbLog=path.join(evidence,'prisma-read-probe.log');await writeFile(dbLog,'');
  await writeFile(preload,`const fs=require('node:fs'),Module=require('node:module');const original=Module._load;Module._load=function(request,parent,isMain){const value=original.apply(this,arguments);if(typeof request==='string'&&(request.includes('@prisma/client')||request.includes('.prisma/client'))&&value.PrismaClient&&!value.__cmsProbe){const Base=value.PrismaClient;const Wrapped=class extends Base{constructor(...args){super(...args);this.$use(async(params,next)=>{const started=Date.now();const result=await next(params);fs.appendFileSync(process.env.UTEN_CMS_READ_DBLOG,JSON.stringify({model:params.model,operation:params.action,ms:Date.now()-started,completedAt:Date.now(),cpuUserMs:process.cpuUsage().user/1000,rows:Array.isArray(result)?result.length:typeof result==='number'?result:result?1:0})+'\\n');return result;});}};return {...value,PrismaClient:Wrapped,__cmsProbe:true};}return value;};`);
  const nextBinary=path.join(websiteRoot,'node_modules/next/dist/bin/next');
  if(production){
    const buildLog=fs.createWriteStream(path.join(evidence,'next-build.log'));
    const selectedRoutes=['products','inquiries','media','releases','resources','cases','jobs','news','series','scenes'].map(scope=>`app/admin/(protected)/${scope}/page.tsx`).concat(['app/admin/login/page.tsx','app/admin/**/releases/*/page.tsx']);
    const buildAdapter=path.join(evidence,'windows-debug-paths.cjs');
    // Next16.4.2 resolves debug selections with '/', while Windows collectAppFiles
    // returns '\\'. Only the task build's selection adapter changes separators;
    // dependencies, product configuration and the runtime engine stay untouched.
    if(windowsDebugPaths)await writeFile(buildAdapter,`const Module=require('node:module'),path=require('node:path');const original=Module._load;Module._load=function(request,parent,isMain){const value=original.apply(this,arguments);const filename=Module._resolveFilename(request,parent).replaceAll('\\\\','/');if(filename.endsWith('/next/dist/lib/resolve-build-paths.js'))return{...value,resolveBuildPaths:async(...args)=>{const result=await value.resolveBuildPaths(...args);return{appPaths:result.appPaths.map(p=>p.replaceAll('/',path.sep)),pagePaths:result.pagePaths.map(p=>p.replaceAll('/',path.sep))};}};return value;};`);
    if(targetedBuild){
      const discoveryCode=`(async()=>{const path=require('node:path'),root=process.cwd();const resolved=await require('next/dist/lib/resolve-build-paths').resolveBuildPaths(JSON.parse(process.argv[1]),root,['tsx','ts','jsx','js']);const discovered=await require('next/dist/build/route-discovery').discoverRoutes({appDir:path.join(root,'app'),pageExtensions:['tsx','ts','jsx','js'],isDev:false,baseDir:root,isSrcDir:false,debugBuildPaths:{app:resolved.appPaths,pages:resolved.pagePaths}});console.log(JSON.stringify({resolved:resolved.appPaths,mapped:Object.keys(discovered.mappedAppPages)}));})().catch(e=>{console.error(e);process.exitCode=1})`;
      const discover=(adapt:boolean)=>JSON.parse(execFileSync(process.execPath,[...(adapt?['--require',buildAdapter]:[]),'-e',discoveryCode,JSON.stringify(selectedRoutes)],{cwd:websiteRoot,windowsHide:true,encoding:'utf8'})) as {resolved:string[];mapped:string[]};
      const before=discover(false),after=windowsDebugPaths?discover(true):before;
      assert.equal(after.resolved.length,12);for(const scope of['products','inquiries','media','releases','resources','cases','jobs','news','series','scenes'])assert.ok(after.mapped.includes(`/admin/(protected)/${scope}/page`));
      assert.ok(after.mapped.includes('/admin/login/page'));assert.ok(after.mapped.includes('/admin/(protected)/releases/[id]/page'));
      await writeFile(path.join(evidence,'route-discovery-before-after.json'),JSON.stringify({before,after,adapterScope:'build selector separators only; no runtime preload'},null,2));
    }
    const buildOptions=`${process.env.NODE_OPTIONS||''} --max-old-space-size=8192${windowsDebugPaths?` --require ${buildAdapter}`:''}`;
    const taskProfile=path.join(evidence,'build-userprofile'),taskLocal=path.join(taskProfile,'AppData/Local'),taskRoaming=path.join(taskProfile,'AppData/Roaming');
    if(isolatedBuildProfile){await mkdir(taskLocal,{recursive:true});await mkdir(taskRoaming,{recursive:true});}
    const buildEnvironment:NodeJS.ProcessEnv={...process.env,...(isolatedBuildProfile?{USERPROFILE:taskProfile,LOCALAPPDATA:taskLocal,APPDATA:taskRoaming}:{}),NODE_OPTIONS:buildOptions,NODE_ENV:'production',NEXT_TELEMETRY_DISABLED:'1',DATABASE_URL:buildFixture!.databaseUrl,AUTH_SECRET:secret,SITE_URL:'https://cms-task.example.invalid'};
    if(isolatedBuildProfile){const actualHome=execFileSync(process.execPath,['-e',"console.log(require('node:os').homedir())"],{windowsHide:true,env:buildEnvironment,encoding:'utf8'}).trim();assert.equal(actualHome,taskProfile);await writeFile(path.join(evidence,'build-profile-isolation.json'),JSON.stringify({onlyChildBuildEnvironment:true,home:actualHome,local:taskLocal,roaming:taskRoaming,runtimeProfileNotChanged:true},null,2));}
    const building=spawn(process.execPath,[nextBinary,'build','--webpack',...(targetedBuild?[`--debug-build-paths=${selectedRoutes.join(',')}`]:[])],{cwd:websiteRoot,windowsHide:true,stdio:['ignore','pipe','pipe'],env:buildEnvironment});
    for(const stream of[building.stdout,building.stderr])stream?.on('data',chunk=>buildLog.write(redact(String(chunk))));
    const buildDeadline=setTimeout(()=>{console.error('Task production build exceeded600-second diagnostic budget; preserving incomplete result.');void stop(building);},600000);
    const code=await new Promise<number|null>((resolve,reject)=>{building.on('error',reject);building.on('exit',resolve);});clearTimeout(buildDeadline);buildLog.end();assert.equal(code,0,'Task Next production build must pass');
    const manifest=JSON.parse(await readFile(path.join(websiteRoot,'.next/server/app-paths-manifest.json'),'utf8')) as Record<string,string>;
    for(const scope of['products','inquiries','media','releases','resources','cases','jobs','news','series','scenes'])assert.ok(manifest[`/admin/(protected)/${scope}/page`],`Actual ${scope} route must be compiled`);
    assert.ok(manifest['/admin/login/page']);assert.ok(manifest['/admin/(protected)/releases/[id]/page']);
    await writeFile(path.join(evidence,'compiled-cms-routes.json'),JSON.stringify({targetedBuild,windowsDebugPaths,manifest},null,2));
    console.log('Actual CMS route manifest verified after production compilation with separate empty isolated build database.');
  }
  next=spawn(process.execPath,[nextBinary,production?'start':'dev',...(production?[]:['--webpack']),'-H','127.0.0.1','-p',String(nextPort)],{cwd:websiteRoot,windowsHide:true,stdio:['ignore','pipe','pipe'],env:{...process.env,NODE_OPTIONS:`${process.env.NODE_OPTIONS||''} --require ${preload}`,UTEN_CMS_READ_DBLOG:dbLog,NODE_ENV:production?'production':'development',DATABASE_URL:fixture.databaseUrl,AUTH_SECRET:secret,SITE_URL:origin}});
  for(const stream of[next.stdout,next.stderr])stream?.on('data',chunk=>nextLog.write(redact(String(chunk))));
  for(let attempt=0;attempt<300;attempt++){try{const ready=await fetch(`${origin}/admin/login`);if(ready.status<500)break;}catch{}if(attempt===299)throw new Error('Task-local Next server did not start');await sleep(200);}
  const unauthenticated=await fetch(`${origin}/admin/products`,{redirect:'manual'});assert.ok([303,307,308].includes(unauthenticated.status),`Unauthenticated CMS status ${unauthenticated.status}`);
  token=await createSessionToken(username,(await db.user.findUniqueOrThrow({where:{username}})).password);
  const edge=process.env.UTEN_CMS_BROWSER||'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
  browser=spawn(edge,['--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check','--disable-background-networking','--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE localhost, EXCLUDE 127.0.0.1','--remote-debugging-port=0',`--user-data-dir=${profile}`,'about:blank'],{windowsHide:true,stdio:'ignore'});
  for(let attempt=0;!fs.existsSync(path.join(profile,'DevToolsActivePort'))&&attempt<200;attempt++)await sleep(50);
  const debuggingPort=Number((await readFile(path.join(profile,'DevToolsActivePort'),'utf8')).split('\n')[0]);
  const targets=await(await fetch(`http://127.0.0.1:${debuggingPort}/json`)).json()as{type:string;webSocketDebuggerUrl:string}[];
  socket=new WebSocket(targets.find(target=>target.type==='page')!.webSocketDebuggerUrl);await new Promise<void>((resolve,reject)=>{socket!.addEventListener('open',()=>resolve(),{once:true});socket!.addEventListener('error',reject,{once:true});});
  let serial=0;const pending=new Map<number,{resolve:(value:any)=>void;reject:(error:Error)=>void}>();const exceptions:string[]=[];
  socket.addEventListener('message',event=>{const message=JSON.parse(String(event.data));if(message.id){const task=pending.get(message.id);pending.delete(message.id);message.error?task?.reject(new Error(JSON.stringify(message.error))):task?.resolve(message.result);}if(message.method==='Runtime.exceptionThrown')exceptions.push(message.params.exceptionDetails.exception?.description||message.params.exceptionDetails.text);});
  const call=(method:string,params:Record<string,unknown>={})=>new Promise<any>((resolve,reject)=>{const id=++serial;pending.set(id,{resolve,reject});socket!.send(JSON.stringify({id,method,params}));});
  async function evaluate<T>(expression:string){const result=await call('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true,userGesture:true});if(result.exceptionDetails)throw new Error(JSON.stringify(result.exceptionDetails));return result.result.value as T;}
  async function waitFor(expression:string,limit=120000){const until=Date.now()+limit;let nextNote=Date.now()+10000;while(Date.now()<until){try{if(await evaluate(expression))return;}catch{}if(Date.now()>nextNote){console.log(JSON.stringify({checkpoint:'browser-wait',state:await evaluate("({url:location.pathname,ready:document.readyState,rows:document.querySelectorAll('[data-cms-continuous] tbody tr').length,title:document.title,loading:document.body?.textContent.includes('正在读取资料')})")}));nextNote=Date.now()+10000;}await sleep(100);}try{const shot=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false});await writeFile(path.join(evidence,'timeout.png'),Buffer.from(shot.data,'base64'));}catch{}throw new Error('Browser condition did not become true: '+expression.slice(0,180));}
  await call('Runtime.enable');await call('Page.enable');await call('Emulation.setDeviceMetricsOverride',{width:1440,height:1000,deviceScaleFactor:1,mobile:false});const installed=await call('Network.setCookie',{name:'uten_admin_session',value:token,url:origin,httpOnly:true,sameSite:'Lax'});assert.equal(installed.success,true);const installedCookies=await call('Network.getCookies',{urls:[origin]});assert.ok(installedCookies.cookies.some((cookie:{name:string;value:string})=>cookie.name==='uten_admin_session'&&cookie.value===token));console.log('Task session cookie installed and checked.');
  inspectBrowser=()=>evaluate("({path:location.pathname,rows:document.querySelectorAll('[data-cms-continuous] tbody tr').length,errors:document.querySelectorAll('[role=alert]').length,busy:document.querySelectorAll('dialog[open][aria-busy=true]').length})");
  const samples=[{count:1,scope:'narrow',suffix:'?q=MODEL-0'},{count:5000,scope:'series',suffix:'?series=benchmark-first-half'},{count:10000,scope:'all',suffix:''},{count:10000,scope:'single-character',suffix:'?q='+encodeURIComponent('连')}];
  for(const sample of samples){const {count}=sample;diagnosticStage=`render-${sample.scope}-${count}`;
    const target=`${origin}/admin/products${sample.suffix}`;if(count===10000){await call('Profiler.enable');await call('Profiler.start');}const started=Date.now();await call('Page.navigate',{url:target});
    await waitFor(`document.querySelectorAll('[data-cms-continuous] tbody tr').length===${count} && document.readyState==='complete'`);
    const readyMs=Date.now()-started;if(count===10000){const cpu=await call('Profiler.stop');await writeFile(path.join(evidence,`browser-10000-${sample.scope}-cpu-profile.json`),JSON.stringify(cpu.profile));await call('Profiler.disable');}await sleep(600);
    const before={...proxyRequests};let wheelScrollY=0,wheelFrameP95:number|null=null;if(count>1){const sampling=evaluate<{frames:number[];sameFirstRow:boolean}>(`new Promise(resolve=>{const first=document.querySelector('[data-cms-continuous] tbody tr');const frames=[];let last=0;function tick(t){if(last)frames.push(t-last);last=t;if(frames.length===60)resolve({frames,sameFirstRow:first===document.querySelector('[data-cms-continuous] tbody tr')});else requestAnimationFrame(tick);}requestAnimationFrame(tick);})`);for(let step=0;step<20;step++){await call('Input.dispatchMouseEvent',{type:'mouseWheel',x:1000,y:650,deltaY:140,deltaX:0});await sleep(16);}const wheels=await sampling;assert.equal(wheels.sameFirstRow,true);wheels.frames.sort((a,b)=>a-b);wheelFrameP95=wheels.frames[Math.floor(wheels.frames.length*.95)];wheelScrollY=await evaluate<number>('scrollY');assert.ok(wheelScrollY>0,'Actual wheel input must move the complete browser table');await evaluate("window.scrollTo({top:0,behavior:'instant'})");await sleep(100);} const result=await evaluate<Record<string,unknown>>(`(async()=>{const table=document.querySelector('[data-cms-continuous]');const first=table.querySelector('tbody tr');const times=[];for(let i=0;i<80;i++){const start=performance.now();window.scrollTo({top:i%4===0?0:i%4===1?document.body.scrollHeight/2:i%4===2?document.body.scrollHeight:0,behavior:'instant'});await new Promise(requestAnimationFrame);times.push(performance.now()-start);}times.sort((a,b)=>a-b);window.scrollTo({top:document.body.scrollHeight,behavior:'instant'});await new Promise(requestAnimationFrame);const tail=table.querySelector('tbody tr:last-child').getBoundingClientRect();const tailVisible=tail.top<innerHeight&&tail.bottom>0;const maxScrollY=scrollY;window.scrollTo({top:0,behavior:'instant'});await new Promise(requestAnimationFrame);return{loadingOverlayVisible:[...document.querySelectorAll('[role=status].fixed')].some(node=>node.checkVisibility()),tailVisible,maxScrollY,navigation:performance.getEntriesByType('navigation')[0]?.toJSON(),rows:table.querySelectorAll('tbody tr').length,sameFirstRow:first===table.querySelector('tbody tr'),tableHeight:table.getBoundingClientRect().height,domNodes:document.querySelectorAll('*').length,scrollFrameP95:times[Math.floor(times.length*.95)],heapBytes:performance.memory?.usedJSHeapSize,hasPaging:[...document.querySelectorAll('a')].some(a=>['上一页','下一页'].includes(a.textContent.trim()))};})()`);
    await sleep(700);assert.equal(result.rows,count);assert.equal(result.loadingOverlayVisible,false);assert.equal(result.tailVisible,true);assert.equal(result.sameFirstRow,true);assert.equal(result.hasPaging,false);assert.equal(proxyRequests.lists,before.lists);assert.equal(proxyRequests.details,before.details);metrics.push({count,scope:sample.scope,readyMs,startedAt:started,profiled:count===10000,wheelScrollY,wheelFrameP95,...result,scrollListRequests:0,scrollDetailRequests:0});console.log(JSON.stringify({checkpoint:'native-table',count,scope:sample.scope,readyMs,wheelScrollY,wheelFrameP95,...result}));
    const shot=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false});await writeFile(path.join(evidence,`cms-${count}${sample.scope==='single-character'?'-single-character':''}.png`),Buffer.from(shot.data,'base64'));
  }
  await evaluate("window.scrollTo({top:0,behavior:'instant'})");await sleep(250);
  await evaluate(`document.querySelector('[data-cms-continuous] tbody tr button').click()`);await waitFor(`Boolean(document.querySelector('dialog[open]'))`);
  const dialogStayed=await evaluate<boolean>(`(async()=>{const dialog=document.querySelector('dialog[open]');window.scrollTo({top:document.body.scrollHeight,behavior:'instant'});await new Promise(requestAnimationFrame);window.scrollTo({top:0,behavior:'instant'});await new Promise(requestAnimationFrame);return dialog===document.querySelector('dialog[open]');})()`);assert.equal(dialogStayed,true);
  diagnosticStage='held-action';dropNextAction='preheaders';await evaluate(`[...document.querySelectorAll('dialog[open] button')].find(button=>button.textContent.trim()==='保存删除草稿').click()`);
  await waitFor(`document.querySelectorAll('dialog[open][aria-busy="true"]').length===1`,30000);
  await evaluate(`(async()=>{for(let i=0;i<20;i++){document.querySelector('[data-cms-continuous] tbody tr button').click();document.querySelector('[data-cms-continuous] tbody tr:nth-child(2) button').click();}window.scrollTo({top:document.body.scrollHeight,behavior:'instant'});await new Promise(requestAnimationFrame);window.scrollTo({top:0,behavior:'instant'});await new Promise(requestAnimationFrame);})()`);
  assert.equal(actions,1);assert.equal(await evaluate(`document.querySelectorAll('dialog[open][aria-busy="true"]').length`),1);
  for(let attempt=0;!releaseUnknownResponse&&attempt<300;attempt++)await sleep(100);
  assert.ok(releaseUnknownResponse,'The held action must have a completed upstream response');
  const held=await db.cmsRevision.findMany({where:{entityType:'product',entityId:'cms-load-000000',operation:'DELETE'},select:{id:true,beforeState:true}});
  console.log(JSON.stringify({checkpoint:'held-write-facts',actions,committedRevisions:held.length}));assert.equal(held.length,1);assert.ok(held[0].beforeState?.includes('UNVERIFIED_LOADING_FIXTURE_BODY'));
  diagnosticStage='preheaders-response-lost';releaseUnknownResponse();
  await waitFor(`!document.querySelector('dialog[open][aria-busy="true"]') && (location.pathname.startsWith('/admin/releases/') || document.body.textContent.includes('请求未完成，请检查版本状态后重试'))`,30000);
  assert.equal(await db.cmsRevision.count({where:{entityId:'cms-load-000000',operation:'DELETE'}}),1,'a browser transport retry must not create a second deletion');
  assert.ok(actions>=1&&actions<=2);const preheadersPosts=actions;
  const preheadersPath=await evaluate<string>('location.pathname');
  if(preheadersPath.startsWith('/admin/releases/'))assert.equal(preheadersPath,`/admin/releases/${held[0].id}`,'a retry must resolve the original immutable revision');
  console.log(JSON.stringify({checkpoint:'preheaders-final',posts:actions,committedRevisions:1,outcome:preheadersPath.startsWith('/admin/releases/')?'confirmed-original':'unknown'}));

  await call('Page.navigate',{url:`${origin}/admin/products?series=benchmark-first-half`});
  await waitFor(`document.querySelectorAll('[data-cms-continuous] tbody tr').length===5000 && document.readyState==='complete'`);
  await evaluate("window.scrollTo({top:0,behavior:'instant'})");
  const bodyActionBase=actions;releaseUnknownResponse=undefined;dropNextAction='body';diagnosticStage='body-loss-held';
  await evaluate(`document.querySelector('[data-cms-continuous] tbody tr:nth-child(2) button').click()`);await waitFor(`Boolean(document.querySelector('dialog[open][role="alertdialog"]'))`);
  await evaluate(`[...document.querySelectorAll('dialog[open] button')].find(button=>button.textContent.trim()==='保存删除草稿').click()`);
  await waitFor(`document.querySelectorAll('dialog[open][aria-busy="true"]').length===1`,30000);
  await evaluate(`for(let i=0;i<20;i++){document.querySelector('[data-cms-continuous] tbody tr button').click();document.querySelector('[data-cms-continuous] tbody tr:nth-child(2) button').click();}`);
  for(let attempt=0;!releaseUnknownResponse&&attempt<300;attempt++)await sleep(100);
  assert.ok(releaseUnknownResponse);assert.equal(actions,bodyActionBase+1);
  assert.equal(await db.cmsRevision.count({where:{entityId:'cms-load-000001',operation:'DELETE'}}),1);
  diagnosticStage='body-response-lost';const unknownReleasedAt=Date.now();(releaseUnknownResponse as ()=>void)();
  await waitFor(`document.body.textContent.includes('请求未完成，请检查版本状态后重试') && !document.querySelector('dialog[open][aria-busy="true"]')`,30000);const unknownBusyClosedMs=Date.now()-unknownReleasedAt;
  diagnosticStage='unknown-settled';assert.equal(actions,bodyActionBase+1);assert.equal(dropped,2);
  assert.equal(await db.cmsRevision.count({where:{entityId:'cms-load-000001',operation:'DELETE'}}),1);
  const countsAfterUnknown={...proxyRequests};await evaluate("window.scrollTo({top:document.body.scrollHeight,behavior:'instant'})");await sleep(250);await evaluate("window.scrollTo({top:0,behavior:'instant'})");await sleep(250);assert.equal(await evaluate(`document.body.textContent.includes('请求未完成，请检查版本状态后重试')`),true);assert.equal(proxyRequests.actions,countsAfterUnknown.actions);assert.equal(proxyRequests.lists,countsAfterUnknown.lists);
  // The original target/snapshot guard still rejects a concurrently removed row.
  await db.product.delete({where:{id:'cms-load-000002'}});
  await evaluate(`document.querySelector('[data-cms-continuous] tbody tr:nth-child(3) button').click()`);await waitFor(`Boolean(document.querySelector('dialog[open][role="alertdialog"]'))`);
  await evaluate(`[...document.querySelectorAll('dialog[open] button')].find(button=>button.textContent.trim()==='保存删除草稿').click()`);
  await waitFor(`document.querySelectorAll('[role="alert"]').length===2 && !document.querySelector('dialog[aria-busy="true"]')`,30000);
  assert.equal(actions,bodyActionBase+2);assert.equal(await db.cmsRevision.count({where:{entityId:'cms-load-000002'}}),0);
  await evaluate(`document.querySelector('[data-cms-continuous] tbody tr:nth-child(4) button').click()`);await waitFor(`Boolean(document.querySelector('dialog[open][role="alertdialog"]'))`);
  await evaluate(`[...document.querySelectorAll('dialog[open] button')].find(button=>button.textContent.trim()==='保存删除草稿').click()`);
  await waitFor(`location.pathname.startsWith('/admin/releases/') && !document.querySelector('dialog[aria-busy="true"]')`,30000);
  assert.equal(actions,bodyActionBase+3);assert.equal(await db.cmsRevision.count({where:{entityId:'cms-load-000003',operation:'DELETE'}}),1);
  assert.deepEqual(exceptions.filter(text=>!text.includes('Failed to fetch')),[]);
  const receipt={result:'PASS',runtime:`actual Next16.4.2/React19 ${production?'production':'development'} server components and native HTML tables in actual browser`,productionBuild:production,physicalDependencies,targetedProductionRoutes:targetedBuild?'10 actual CMS lists, login and release detail with original layouts/actions':null,fullSiteBuildVerified:false,fixtureOnly:true,companyUat:false,unauthenticatedStatus:unauthenticated.status,metrics,confirmationSurvivedScroll:true,heldAction:{busyDialogs:1,repeatedClicks:20,postsBeforeFault:1},preheadersResponseLoss:{posts:preheadersPosts,committedDrafts:1,originalRevisionReused:true},unknownResponse:{committedDrafts:1,posts:1,replays:0,sourceSnapshotBodyPreserved:true,busyClosed:true,busyClosedMs:unknownBusyClosedMs},staleObject:{posts:1,createdRevisions:0,busyClosed:true},successfulCommand:{posts:1,createdDrafts:1,navigatedToOriginalReleaseDetail:true,busyClosed:true},browserExceptions:exceptions.filter(text=>!text.includes('Failed to fetch')),finishedAt:new Date().toISOString()};
  await writeFile(path.join(evidence,'cms-browser-receipt.json'),JSON.stringify(receipt,null,2)+'\n');console.log(JSON.stringify(receipt));
}finally{
  try{await writeFile(path.join(evidence,'action-outcome-diagnostic.json'),JSON.stringify({stage:diagnosticStage,actions,dropped,metrics,revisions:await db.cmsRevision.groupBy({by:['entityId','operation'],where:{entityId:{in:['cms-load-000000','cms-load-000001','cms-load-000002','cms-load-000003']}},_count:{_all:true}}),browser:await inspectBrowser?.().catch(()=>null)},null,2));}catch{}
  socket?.close();await stop(browser);await stop(next);proxy.closeAllConnections();await new Promise<void>(resolve=>proxy.close(()=>resolve()));nextLog.end();await db.$disconnect();await fixture.dispose();await buildFixture?.dispose();
  if(path.dirname(profile)!==evidence||!path.basename(profile).startsWith('cms-headless-'))throw new Error('Unexpected task browser profile path');await rm(profile,{recursive:true,force:true,maxRetries:10,retryDelay:100});
}

}
main().catch(error=>{console.error(error);process.exitCode=1;});
