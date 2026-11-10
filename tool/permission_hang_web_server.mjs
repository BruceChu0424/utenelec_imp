// Isolated HTTP/auth fixture for the production Flutter permissions/status pages.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
const root=path.resolve('build/permission-hang-web');
const out=path.resolve('build/permission-hang-evidence');
fs.mkdirSync(out,{recursive:true});
let epoch=0,refreshes=0,reads=0,statusReads=0,delay=0;
const writes=[], requests=[],cancelled=[],noticeQueries=[],noticeCancelled=[];
// The final employee starts with a different authoritative value, so a late
// response from either earlier employee is observable after rapid switching.
const grants=new Map([['fixture-2',['goods:view']]]);
const rows=Array.from({length:3},(_,i)=>({id:`fixture-${i}`,employeeId:`employee-${i}`,employeeName:`回归员工${i+1}`,employeeCode:`E00${i+1}`,employeeStatus:'active',currentEmployee:true,loginAccount:`fixture${i}`,status:'active',mustChangePassword:false,remoteAccess:false}));
const json=(res,value,status=200)=>{res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(value));};
const server=http.createServer(async(req,res)=>{
  const url=new URL(req.url,'http://127.0.0.1'),route=url.pathname;
  if(route==='/_probe/state')return json(res,{epoch,refreshes,reads,statusReads,writes,requests,cancelled,noticeQueries,noticeCancelled});
  if(route==='/_probe/delay'){delay=Number(url.searchParams.get('ms'));return json(res,{delay});}
  if(route.startsWith('/api/')){
    let raw='';for await(const chunk of req)raw+=chunk;
    if(route==='/api/auth/refresh'){
      refreshes++;requests.push([req.method,route,200]);
      return json(res,{accessToken:`fixture-access-${epoch}`,refreshToken:'fixture-refresh',expiresIn:900});
    }
    if(req.headers.authorization!==`Bearer fixture-access-${epoch}`){
      requests.push([req.method,route,401]);return json(res,{code:'UNAUTHORIZED',message:'Fixture epoch changed'},401);
    }
    requests.push([req.method,route,200]);
    const effective=route.match(/^\/api\/admin\/users\/(fixture-\d)\/effective-permissions$/);
    const override=route.match(/^\/api\/admin\/users\/(fixture-\d)\/permission-overrides$/);
    if(override&&req.method==='PUT'){
      const body=JSON.parse(raw),before=grants.get(override[1])??[],after=body.grants;
      grants.set(override[1],after);writes.push({id:override[1],grants:after,revokes:body.revokes});epoch++;
      return json(res,{added:after.filter(x=>!before.includes(x)),removed:before.filter(x=>!after.includes(x))});
    }
    if(effective){
      reads++;res.on('close',()=>{if(!res.writableEnded)cancelled.push(effective[1]);});
      const snapshot=grants.get(effective[1])??[];
      if(delay)await new Promise(r=>setTimeout(r,delay));
      return json(res,{grants:snapshot,revokes:[],effective:snapshot,confirmedGrants:snapshot,superAdmin:false});
    }
    if(route==='/api/admin/users')return json(res,{items:rows,page:1,size:Number(url.searchParams.get('size'))||50,total:rows.length,totalPages:1});
    if(route==='/api/admin/permission-catalog')return json(res,[{module:'回归业务',category:'权限链路',permissions:[{id:'fixture-view',code:'goods:view',name:'回归查看权限',module:'回归业务',category:'权限链路',actionType:'VIEW'}]}]);
    if(route==='/api/admin/permission-baseline')return json(res,{permissions:[]});
    if(route==='/api/admin/permission-templates/bindings'||route==='/api/org/departments/tree')return json(res,[]);
    if(route==='/api/admin/server-status'){
      statusReads++;return json(res,{status:'NORMAL',sampledAt:new Date().toISOString(),refreshAfterSeconds:15,environment:'权限回归环境',applicationVersion:'fixture-current',uptimeSeconds:3600,metrics:[],disks:[],database:{},backup:{},alerts:[]});
    }
    if(route==='/api/admin/server-storage')return json(res,{available:false,volumes:[]});
    if(route==='/api/workbench/badges')return json(res,{});
    if(route==='/api/notices'){
      const filter=url.searchParams.has('importantOnly')?'important':url.searchParams.has('onlyUnread')?'unread':'all';
      noticeQueries.push(filter);
      res.on('close',()=>{if(!res.writableEnded)noticeCancelled.push(filter);});
      if(filter==='all')await new Promise(r=>setTimeout(r,2500));
      const title=filter==='important'?'重要回归通知':filter==='unread'?'未读回归通知':'全部迟到回归通知';
      return json(res,{items:[{id:`fixture-notice-${filter}`,title,content:'本地合成通知',type:'system',publisher:'回归服务',publishedAt:new Date().toISOString(),isRead:false}]});
    }
    requests[requests.length-1][2]=404;return json(res,{code:'NOT_FOUND',message:'Unexpected fixture endpoint'},404);
  }
  const target=path.resolve(root,'.'+(route==='/'?'/index.html':decodeURIComponent(route)));
  if(!target.startsWith(root+path.sep)){res.writeHead(403);res.end();return;}
  try{
    const ext=path.extname(target);res.setHeader('Content-Type',({'.js':'text/javascript','.wasm':'application/wasm','.html':'text/html','.json':'application/json','.png':'image/png','.ttf':'font/ttf','.otf':'font/otf'})[ext]??'application/octet-stream');
    res.setHeader('Cache-Control','no-store');res.end(fs.readFileSync(target));
  }catch{res.writeHead(404);res.end('Not found');}
});
server.listen(0,'127.0.0.1',()=>{
  const owner={pid:process.pid,port:server.address().port,root};
  fs.writeFileSync(path.join(out,'server-owner.json'),JSON.stringify(owner));console.log(JSON.stringify(owner));
});
