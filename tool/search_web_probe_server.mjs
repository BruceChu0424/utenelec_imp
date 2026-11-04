import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
const root=path.resolve('build/search-web');
const queries=[];const requests=[];const cancelled=[];let revision=0;
function row(id,name,code){return {id,employeeId:'employee-'+id,employeeName:name,employeeCode:code,employeeStatus:'active',currentEmployee:true,loginAccount:'fixture-'+code,status:'active',mustChangePassword:false,remoteAccess:false};}
const server=http.createServer(async(req,res)=>{
 const url=new URL(req.url,'http://127.0.0.1');
 if(url.pathname==='/_probe/bump' && req.method==='POST'){revision++;res.end('ok');return;}
 if(url.pathname==='/_probe/state'){res.setHeader('Content-Type','application/json');res.end(JSON.stringify({queries,requests,cancelled}));return;}
 if(url.pathname==='/api/admin/users'){
  const query=url.searchParams.get('search')??'';queries.push(query);requests.push([req.method,url.pathname]);
  res.on('close',()=>{if(!res.writableEnded)cancelled.push(query);});
  if(query==='旧')await new Promise(r=>setTimeout(r,900));
  const rows=query==='张'?[row('a','张伟','E001'),row('b','张敏','E002')]:query==='张 E001'?[row('a',revision?'张伟更新':'张伟','E001')]:query==='新'?[row('new','新结果员工','E003')]:query==='旧'?[row('old','旧结果员工','E004')]:query==='不存在'?[]:[row('initial','初始员工','E000')];
  res.setHeader('Content-Type','application/json');res.end(JSON.stringify({items:rows,page:1,size:20,total:rows.length,totalPages:rows.length?1:0}));return;
 }
 if(url.pathname.startsWith('/api/')){requests.push([req.method,url.pathname]);res.writeHead(404,{'Content-Type':'application/json'});res.end(JSON.stringify({code:'NOT_FOUND',message:'Unexpected probe endpoint'}));return;}
 const target=path.resolve(root,'.'+(url.pathname==='/'?'/index.html':decodeURIComponent(url.pathname)));
 if(!target.startsWith(root+path.sep)&&target!==root){res.writeHead(403);res.end();return;}
 try{const bytes=fs.readFileSync(target);const ext=path.extname(target);res.setHeader('Content-Type',({'.js':'text/javascript','.wasm':'application/wasm','.html':'text/html','.json':'application/json','.png':'image/png','.ttf':'font/ttf','.otf':'font/otf'})[ext]??'application/octet-stream');res.setHeader('Cache-Control','no-store');res.end(bytes);}catch{res.writeHead(404);res.end('Not Found');}
});
server.listen(0,'127.0.0.1',()=>{const receipt={pid:process.pid,port:server.address().port,root,fixture:true};fs.writeFileSync('build/search-web-owner.json',JSON.stringify(receipt,null,2));console.log(JSON.stringify(receipt));});
