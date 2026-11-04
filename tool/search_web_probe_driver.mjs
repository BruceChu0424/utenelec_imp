import fs from 'node:fs';
const owner=JSON.parse(fs.readFileSync('build/search-web-browser-owner.json','utf8').replace(/^\uFEFF/,''));
for(let i=0;!fs.existsSync(owner.profile+'/DevToolsActivePort')&&i<200;i++)await new Promise(r=>setTimeout(r,50));
const port=Number(fs.readFileSync(owner.profile+'/DevToolsActivePort','utf8').split('\n')[0]);
const pages=await(await fetch(`http://127.0.0.1:${port}/json`)).json();
const page=pages.find(p=>p.type==='page');
const socket=new WebSocket(page.webSocketDebuggerUrl);
await new Promise((resolve,reject)=>{socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',reject,{once:true});});
let serial=0;const pending=new Map();const exceptions=[];
socket.addEventListener('message',event=>{const value=JSON.parse(event.data);if(value.id){const op=pending.get(value.id);pending.delete(value.id);value.error?op?.reject(new Error(JSON.stringify(value.error))):op?.resolve(value.result);}if(value.method==='Runtime.exceptionThrown')exceptions.push(value.params.exceptionDetails.exception?.description??value.params.exceptionDetails.text);});
const call=(method,params={})=>new Promise((resolve,reject)=>{const id=++serial;pending.set(id,{resolve,reject});socket.send(JSON.stringify({id,method,params}));});
async function evaluate(expression){const r=await call('Runtime.evaluate',{expression,returnByValue:true});if(r.exceptionDetails)throw new Error(JSON.stringify(r.exceptionDetails));return r.result.value;}
const state=async()=>await(await fetch(`http://127.0.0.1:${owner.port}/_probe/state`)).json();
const text=()=>evaluate('document.body.innerText');
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function until(label,predicate){for(let i=0;i<160;i++){if(await predicate())return;await sleep(50);}throw new Error('Timeout: '+label+'; page='+await text());}
async function focusSearch(){
 const rect=await evaluate("(()=>{const e=document.querySelector('input[data-semantics-role=\"text-field\"]');const r=e.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2};})()");
 await call('Input.dispatchMouseEvent',{type:'mousePressed',...rect,button:'left',clickCount:1});
 await call('Input.dispatchMouseEvent',{type:'mouseReleased',...rect,button:'left',clickCount:1});
}
async function search(value){
 const rect=await evaluate("(()=>{const e=document.querySelector('input[data-semantics-role=\"text-field\"]');if(!e)return null;const r=e.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2};})()");
 if(!rect)throw new Error('Search field not accessible');
 await call('Input.dispatchMouseEvent',{type:'mousePressed',...rect,button:'left',clickCount:1});
 await call('Input.dispatchMouseEvent',{type:'mouseReleased',...rect,button:'left',clickCount:1});
 await call('Input.dispatchKeyEvent',{type:'keyDown',key:'a',code:'KeyA',windowsVirtualKeyCode:65,modifiers:2});
 await call('Input.dispatchKeyEvent',{type:'keyUp',key:'a',code:'KeyA',windowsVirtualKeyCode:65,modifiers:2});
 await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Backspace',code:'Backspace',windowsVirtualKeyCode:8});
 await call('Input.dispatchKeyEvent',{type:'keyUp',key:'Backspace',code:'Backspace',windowsVirtualKeyCode:8});
 if(value)await call('Input.insertText',{text:value});
}
await call('Runtime.enable');
await call('Page.reload');
await until('Flutter semantics ready',()=>evaluate("document.querySelector('flt-semantics-placeholder')!==null || document.querySelector('input[data-semantics-role=\"text-field\"]')!==null"));
await evaluate("document.querySelector('flt-semantics-placeholder')?.click()");
await until('initial production list',async()=>(await text()).includes('初始员工'));
const scenarios=[];
await search('张');await until('single-character query',async()=>(await state()).queries.includes('张'));
await until('single-character two results',async()=>{const t=await text();return t.includes('张伟')&&t.includes('张敏');});scenarios.push('single Chinese character search');
await search('张 E001');await until('multi-field query',async()=>(await state()).queries.includes('张 E001'));
await until('multi-field exact result',async()=>{const t=await text();return t.includes('张伟')&&!t.includes('张敏');});scenarios.push('name plus employee-code terms');
await search('旧');await until('delayed old request entered',async()=>(await state()).queries.includes('旧'));
const oldCount=(await state()).queries.filter(q=>q==='旧').length;
for(let i=0;i<2;i++){await focusSearch();await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Enter',code:'Enter',windowsVirtualKeyCode:13});await call('Input.dispatchKeyEvent',{type:'keyUp',key:'Enter',code:'Enter',windowsVirtualKeyCode:13});}
await sleep(100);if((await state()).queries.filter(q=>q==='旧').length!==oldCount)throw new Error('In-flight same-query Enter reissued');scenarios.push('in-flight same-query Enter is suppressed');
await search('新');await until('new result',async()=>(await text()).includes('新结果员工'));
await sleep(1100);if((await text()).includes('旧结果员工'))throw new Error('Late response published');scenarios.push('retire/cancel delayed old query');
for(let i=0;i<20;i++){await search(i%2===0?'张':'新');await sleep(10);}
await until('rapid input settles on current query',async()=>(await text()).includes('新结果员工'));scenarios.push('20 rapid repeat edits');
await search('不存在');await until('empty result',async()=>(await text()).includes('暂无匹配的员工账号'));scenarios.push('empty result');
await search('张 E001');await until('recover after empty',async()=>{const t=await text();return t.includes('张伟')&&!t.includes('张敏');});scenarios.push('recover from empty without losing input');
const refreshBefore=(await state()).queries.length;
await fetch(`http://127.0.0.1:${owner.port}/_probe/bump`,{method:'POST'});
await focusSearch();await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Enter',code:'Enter',windowsVirtualKeyCode:13});await call('Input.dispatchKeyEvent',{type:'keyUp',key:'Enter',code:'Enter',windowsVirtualKeyCode:13});
await until('same-query Enter rereads new data',async()=>(await state()).queries.length>refreshBefore&&(await text()).includes('张伟更新'));await sleep(400);
if((await state()).queries.length!==refreshBefore+1)throw new Error('Same-query refresh duplicated');scenarios.push('completed same-query Enter rereads changed data');
const before=(await state()).queries.length;
await search('张');await focusSearch();await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Enter',code:'Enter',windowsVirtualKeyCode:13});await call('Input.dispatchKeyEvent',{type:'keyUp',key:'Enter',code:'Enter',windowsVirtualKeyCode:13});
await until('Enter single request',async()=>(await state()).queries.length>before);await sleep(450);
const enterQueries=(await state()).queries.slice(before);
if(enterQueries.length!==1||enterQueries[0]!=='张')throw new Error('Enter caused duplicate or wrong query: '+JSON.stringify(enterQueries));scenarios.push('Enter dispatches once without debounce replay');
await until('final rows visible',async()=>{const t=await text();return t.includes('张伟')&&t.includes('张敏');});
const result=await state();
if(!result.requests.every(([method,url])=>method==='GET'&&url==='/api/admin/users'))throw new Error('Unexpected API call');
if(exceptions.length)throw new Error('Browser exceptions: '+exceptions.join('; '));
const screenshot=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false});
fs.mkdirSync('build/search-web-evidence',{recursive:true});
fs.writeFileSync('build/search-web-evidence/permission-search.png',Buffer.from(screenshot.data,'base64'));
const receipt={result:'PASS',runtime:'Flutter release JavaScript/CanvasKit in real headless Chrome',fixture:'loopback-only HTTP; production ApiClient/DioAdminRepository/AdminPermissionsPage',scenarios,requests:result.requests,queries:result.queries,cancelled:result.cancelled,browserExceptions:exceptions,screenshot:'build/search-web-evidence/permission-search.png',companyUat:false};
fs.writeFileSync('build/search-web-evidence/receipt.json',JSON.stringify(receipt,null,2));console.log(JSON.stringify(receipt));socket.close();
