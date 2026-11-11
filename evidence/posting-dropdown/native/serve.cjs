const http=require('http');
const fs=require('fs');
const path=require('path');
const root=path.resolve(process.argv[2]);
const port=Number(process.argv[3]);
const mime={'.html':'text/html; charset=utf-8','.js':'application/javascript','.json':'application/json','.wasm':'application/wasm','.css':'text/css','.svg':'image/svg+xml','.png':'image/png','.jpg':'image/jpeg','.ttf':'font/ttf','.woff2':'font/woff2'};
http.createServer((req,res)=>{
 let relative;
 try{relative=decodeURIComponent(new URL(req.url,'http://127.0.0.1').pathname).replace(/^\/+/, '');}catch{res.writeHead(400);res.end();return;}
 if(relative==='api'||relative.startsWith('api/')){res.writeHead(404,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end('{"code":"SYNTHETIC_ONLY_NO_BACKEND"}');return;}
 let file=path.resolve(root,relative||'index.html');
 if(file!==root&&!file.startsWith(root+path.sep)){res.writeHead(403);res.end();return;}
 if(!fs.existsSync(file)||fs.statSync(file).isDirectory())file=path.join(root,'index.html');
 res.writeHead(200,{'Content-Type':mime[path.extname(file)]||'application/octet-stream','Cache-Control':'no-store'});
 fs.createReadStream(file).pipe(res);
}).listen(port,'127.0.0.1',()=>process.stdout.write(JSON.stringify({ready:true,address:'127.0.0.1',port,root})+'\n'));
