// Real API passthrough and static Debug Web. Optional transport fault drops a
// summary stream after its first real frame; it never fabricates API values.
import http from 'node:http';
import {holdExactPost} from './submit_hold.mjs';
import fs from 'node:fs';
import path from 'node:path';
const base=path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/,'$1'));
const web=path.join(base,'web');
const settings=JSON.parse(fs.readFileSync(path.join(base,'private/runtime.json'),'utf8'));
const runTag=process.argv[2];
if(!runTag || !/^[a-zA-Z0-9_-]+$/.test(runTag))throw new Error('Supply a new evidence run tag');
const liveLogs=path.join(base,'private/runtime-logs');
fs.mkdirSync(liveLogs,{recursive:true});
// Refuse reuse. Copy this closed raw file into the acceptance evidence later;
// a live logger must not keep changing an already committed receipt.
const log=fs.createWriteStream(path.join(liveLogs,`proxy-${runTag}.jsonl`),{flags:'wx'});
const mime={'.html':'text/html','.js':'application/javascript','.mjs':'application/javascript','.json':'application/json','.css':'text/css','.wasm':'application/wasm','.ttf':'font/ttf','.otf':'font/otf','.woff2':'font/woff2','.png':'image/png','.svg':'image/svg+xml'};
function faultEnabled(){
  try{return JSON.parse(fs.readFileSync(path.join(base,'private/fault.json'),'utf8')).dropMouldAfterFirstFrame===true;}
  catch{return false;}
}
function committedReplyLoss(pathname){
  try{return JSON.parse(fs.readFileSync(path.join(base,'private/fault.json'),'utf8')).loseCommittedReplyPaths?.includes(pathname)===true;}
  catch{return false;}
}
function consumeCommittedReplyLoss(pathname){
  const file=path.join(base,'private/fault.json'),value=JSON.parse(fs.readFileSync(file,'utf8'));
  value.loseCommittedReplyPaths=value.loseCommittedReplyPaths.filter(item=>item!==pathname);
  fs.writeFileSync(file,JSON.stringify(value));
}
http.createServer((req,res)=>{
  const url=new URL(req.url,`http://127.0.0.1:${settings.frontendPort}`);
  if(url.pathname.startsWith('/api/')||url.pathname.startsWith('/actuator/')) {
    const forward=()=>{
    const started=Date.now();
    const drop=faultEnabled()&&url.pathname==='/api/master/moulds/summaries';
    const loseReply=req.method==='POST'&&committedReplyLoss(url.pathname);
    const upstream=http.request({hostname:'127.0.0.1',port:settings.backendPort,path:req.url,method:req.method,
      headers:{...req.headers,host:`127.0.0.1:${settings.backendPort}`}},reply=>{
      if(loseReply&&reply.statusCode>=200&&reply.statusCode<300){
        // Wait for the real server's complete successful response, then lose
        // only its delivery. No body, credential or business value is logged.
        consumeCommittedReplyLoss(url.pathname);
        reply.resume();
        reply.on('end',()=>{
          log.write(JSON.stringify({path:url.pathname,method:req.method,status:reply.statusCode,ms:Date.now()-started,faultInjected:'committed-response-loss'})+'\n');
          res.destroy();
        });
        return;
      }
      res.writeHead(reply.statusCode,reply.headers);
      if(!drop){
        reply.pipe(res);
        reply.on('end',()=>log.write(JSON.stringify({path:url.pathname,method:req.method,status:reply.statusCode,ms:Date.now()-started,faultInjected:false})+'\n'));
      } else {
        let prefix=Buffer.alloc(0),sent=false;
        reply.on('data',chunk=>{
          if(sent)return;
          prefix=Buffer.concat([prefix,chunk]);
          const end=prefix.indexOf(10);
          if(end<0)return;
          sent=true;res.write(prefix.subarray(0,end+1));
          setTimeout(()=>{
            log.write(JSON.stringify({path:url.pathname,method:req.method,status:reply.statusCode,ms:Date.now()-started,faultInjected:true,firstFrameBytes:end+1})+'\n');
            res.destroy();reply.destroy();
          },700);
        });
      }
    });
    upstream.on('error',()=>{if(!res.headersSent)res.writeHead(502);res.end();});
    req.pipe(upstream);};
    if(holdExactPost(req,res,url.pathname,path.join(base,'private'),forward,item=>log.write(JSON.stringify(item)+'\n')))return;
    forward();return;
  }
  let file=path.resolve(web,'.'+decodeURIComponent(url.pathname));
  if(!file.startsWith(web+path.sep)&&file!==web){res.writeHead(400);res.end();return;}
  if(!fs.existsSync(file)||fs.statSync(file).isDirectory())file=path.join(web,'index.html');
  res.writeHead(200,{'Content-Type':mime[path.extname(file)]||'application/octet-stream','Cache-Control':'no-store'});
  fs.createReadStream(file).pipe(res);
}).listen(settings.frontendPort,'127.0.0.1',()=>console.log(`Local Debug Web :${settings.frontendPort} -> backend :${settings.backendPort}`));
