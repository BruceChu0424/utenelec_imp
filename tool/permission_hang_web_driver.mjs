// Drives the actual Flutter semantics through mouse/keyboard events in Chrome.
import fs from 'node:fs';
import path from 'node:path';
import {spawn} from 'node:child_process';
const out=path.resolve('build/permission-hang-evidence');
const rounds=Number(process.env.UTEN_PERMISSION_PROBE_ROUNDS??24);
if(![6,24].includes(rounds))throw new Error('Probe rounds must be 6 or 24');
const owner=JSON.parse(fs.readFileSync(path.join(out,'server-owner.json'),'utf8'));
const profile=path.join(out,`chrome-${Date.now()}`);
const browser=spawn(process.env.CHROME_EXECUTABLE||'C:/Program Files/Google/Chrome/Application/chrome.exe',[
  '--headless=new','--disable-gpu','--no-first-run','--disable-background-networking',
  '--remote-debugging-port=0',`--user-data-dir=${profile}`,'--window-size=1600,1100',
  `http://127.0.0.1:${owner.port}/`],{windowsHide:true,stdio:['ignore','ignore','pipe']});
const errors=fs.createWriteStream(path.join(out,'chrome.log'));browser.stderr.pipe(errors);
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
let socket,captureFailure;
const scenarios=[];const exceptions=[];
const consoleEvents=[],exceptionProperties=[];
const state=async()=>await(await fetch(`http://127.0.0.1:${owner.port}/_probe/state`)).json();
try{
  for(let i=0;i<200&&!fs.existsSync(path.join(profile,'DevToolsActivePort'));i++)await sleep(50);
  const port=Number(fs.readFileSync(path.join(profile,'DevToolsActivePort'),'utf8').split('\n')[0]);
  const pages=await(await fetch(`http://127.0.0.1:${port}/json`)).json();
  socket=new WebSocket(pages.find(p=>p.type==='page').webSocketDebuggerUrl);
  await new Promise((resolve,reject)=>{socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',reject,{once:true});});
  let serial=0;const pending=new Map();
  socket.addEventListener('message',event=>{const v=JSON.parse(event.data);if(v.id){const p=pending.get(v.id);pending.delete(v.id);v.error?p?.reject(new Error(JSON.stringify(v.error))):p?.resolve(v.result);}if(v.method==='Runtime.consoleAPICalled')consoleEvents.push(v.params);if(v.method==='Runtime.exceptionThrown'){exceptions.push(v.params.exceptionDetails);const id=v.params.exceptionDetails.exception?.objectId;if(id)call('Runtime.getProperties',{objectId:id,ownProperties:true}).then(r=>exceptionProperties.push(r));}});
  const call=(method,params={})=>new Promise((resolve,reject)=>{const id=++serial;pending.set(id,{resolve,reject});socket.send(JSON.stringify({id,method,params}));});
  const evaluate=async expression=>{const r=await call('Runtime.evaluate',{expression,returnByValue:true});if(r.exceptionDetails)throw new Error(JSON.stringify(r.exceptionDetails));return r.result.value;};
  const text=()=>evaluate("document.body.innerText+'\\n'+[...document.querySelectorAll('[aria-label]')].map(e=>e.getAttribute('aria-label')).join('\\n')");
  const until=async(label,predicate)=>{for(let i=0;i<200;i++){if(await predicate())return;await sleep(50);}throw new Error(`Timeout ${label}; page=${await text()}; state=${JSON.stringify(await state())}`);};
  const click=async(label,role)=>{
    const rect=await evaluate(`(()=>{const label=${JSON.stringify(label)};const name=e=>(e.getAttribute('aria-label')??e.innerText??'').trim();const els=[...document.querySelectorAll(${JSON.stringify(`[role="${role??'button'}"]`)} )].filter(e=>label==null||name(e).includes(label)).sort((a,b)=>name(a).length-name(b).length);const e=els[0];if(!e)return null;const r=e.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2};})()`);
    if(!rect)throw new Error(`Missing control ${label}; page=${await text()}`);
    await call('Input.dispatchMouseEvent',{type:'mousePressed',...rect,button:'left',clickCount:1});
    await call('Input.dispatchMouseEvent',{type:'mouseReleased',...rect,button:'left',clickCount:1});
  };
  const screenshot=async name=>{const r=await call('Page.captureScreenshot',{format:'png'});fs.writeFileSync(path.join(out,name),Buffer.from(r.data,'base64'));};
  captureFailure=async()=>{await screenshot('browser-failure.png');fs.writeFileSync(path.join(out,'failure-dom.html'),await evaluate('document.body.outerHTML'));};
  await call('Runtime.enable');
  await until('semantics',()=>evaluate("document.querySelector('flt-semantics-placeholder')!==null"));
  await evaluate("document.querySelector('flt-semantics-placeholder').click()");
  await until('employees',async()=>(await text()).includes('回归员工1'));
  // Save a bounded inventory to keep failures diagnosable without business data.
  fs.writeFileSync(path.join(out,'initial-dom.html'),await evaluate('document.body.outerHTML'));
  const select=async i=>{
    const label=`回归员工${i+1}(E00${i+1})`;
    const before=(await state()).reads;
    await click(label);
    await until('selected employee read starts',async()=>(await state()).reads>before);
    await until('permission module',async()=>(await text()).includes('回归业务'));
    await until('permission expansion control',async()=>/全部展开|全部折叠/.test(await text()));
    if((await text()).includes('全部展开'))await click('全部展开');
    await until('permission switch',()=>evaluate("document.querySelector('[role=switch]')!==null"));
  };
  for(let round=0;round<rounds;round++){
    await select(round%3);
    const switchLabel=await evaluate("document.querySelector('[role=switch]').getAttribute('aria-label')");
    await click(switchLabel,'switch');
    await until('dirty save button',async()=>(await text()).includes('保存更改'));
    const requestOffset=(await state()).requests.length;
    await click('保存更改','button');
    await until('exactly one permission command',async()=>(await state()).writes.length===round+1);
    const saved=(await state()).writes[round];
    const expectedGrants=((Math.floor(round/3)%2===0)!==(round%3===2))?['goods:view']:[];
    if(saved.id!==`fixture-${round%3}`||JSON.stringify(saved.grants)!==JSON.stringify(expectedGrants)||saved.revokes.length)throw new Error('Saved permission belongs to the wrong account or state');
    await until('authoritative readback and rendered value after 401',async()=>{
      const s=await state(), attempts=s.requests.slice(requestOffset);
      const target=`/api/admin/users/${saved.id}/effective-permissions`;
      const denied=attempts.findIndex(([method,route,status])=>method==='GET'&&route===target&&status===401);
      const recovered=denied>=0&&attempts.slice(denied+1).some(([method,route,status])=>method==='GET'&&route===target&&status===200);
      const page=await text();
      return recovered&&s.refreshes===round+1&&!page.includes('保存更改')&&page.includes(expectedGrants.length?'已授权 1':'未授权 1');
    });
  }
  scenarios.push(`${rounds} permission changes across three accounts with real 401-refresh-replay; one write per click`);
  await screenshot(`permissions-after-${rounds}.png`);
  await click('回归：服务器状态','button');
  await until('server status readable',async()=>(await text()).includes('fixture-current'));
  scenarios.push('server status loads after all repeated permission updates');
  await screenshot(`server-status-after-${rounds}.png`);
  for(let round=0;round<5;round++){
    await click('回归：离开页面','button');await until('left',async()=>(await text()).includes('已离开'));
    await click('回归：账号权限','button');await until('reopened',async()=>(await text()).includes('回归员工1'));
    await select(round%3);
  }
  scenarios.push('five real close/reopen cycles retain working reads');
  await fetch(`http://127.0.0.1:${owner.port}/_probe/delay?ms=2500`);
  await click('回归：离开页面','button');await until('retire before rapid switching',async()=>(await text()).includes('已离开'));
  await click('回归：账号权限','button');
  await until('rapid employees',async()=>(await text()).includes('回归员工1'));
  for(let i=0;i<18;i++){
    const before=(await state()).reads;
    await click(`回归员工${i%3+1}(E00${i%3+1})`);
    await until('delayed read dispatched before switching away',async()=>(await state()).reads>before);
    await sleep(90);
  }
  await until('latest employee renders its own authoritative grant',async()=>(await text()).includes('回归业务')&&(await text()).includes('已授权 1'));
  await click('回归：通知','button');
  await until('notification page',async()=>(await text()).includes('未读回归通知'));
  for(let round=0;round<6;round++){
    const before=(await state()).noticeQueries.length;
    await click('全部','button');
    await until('delayed notification filter dispatched',async()=>(await state()).noticeQueries.length>before);
    await click('重要','button');
    await until('latest notification filter published',async()=>(await text()).includes('重要回归通知'));
  }
  await sleep(2700);
  if((await text()).includes('全部迟到回归通知'))throw new Error('Late notification filter replaced current list');
  await screenshot('notification-latest-filter.png');
  const result=await state();
  if(result.writes.length!==rounds)throw new Error('Unexpected write replay');
  if(result.cancelled.length<6)throw new Error('Retired transports were not cancelled');
  if(result.noticeCancelled.length!==6)throw new Error('Retired notification transports were not cancelled');
  if(result.requests.some(r=>r[2]===404))throw new Error('Unexpected HTTP endpoint');
  if(exceptions.length)throw new Error(JSON.stringify(exceptions));
  scenarios.push('18 rapid employee switches cancel retired HTTP reads, publish latest result only');
  scenarios.push('six delayed notification filters cancelled; latest filter remains after all late responses');
  const receipt={passed:true,runtime:'Actual headless Chrome; Flutter release production pages, ApiClient, AuthInterceptor, DioAdminRepository, DioNoticeRepository; loopback-only synthetic HTTP',companyUat:false,scenarios,refreshes:result.refreshes,writes:result.writes.length,cancelled:result.cancelled.length,noticeCancelled:result.noticeCancelled.length,statusReads:result.statusReads,browserExceptions:exceptions};
  fs.writeFileSync(path.join(out,'browser-receipt.json'),JSON.stringify(receipt,null,2));console.log(JSON.stringify(receipt));
}catch(error){
  await captureFailure?.();
  fs.writeFileSync(path.join(out,'browser-failure.txt'),String(error));console.error(String(error));process.exitCode=1;
}finally{fs.writeFileSync(path.join(out,'browser-runtime-events.json'),JSON.stringify({exceptions,exceptionProperties,consoleEvents},null,2));socket?.close();browser.kill();errors.end();}
