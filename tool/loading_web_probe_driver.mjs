import fs from 'node:fs';
const evidenceRoot = process.argv[2] ?? 'build/loading-validation';
const owner = JSON.parse(fs.readFileSync(evidenceRoot + '/web-browser-owner.json', 'utf8').replace(/^\uFEFF/, ''));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
for (let n=0; !fs.existsSync(owner.profile+'/DevToolsActivePort') && n<200; n++) await sleep(50);
const port = Number(fs.readFileSync(owner.profile+'/DevToolsActivePort','utf8').split('\n')[0]);
const pages = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
const socket = new WebSocket(pages.find(p=>p.type==='page').webSocketDebuggerUrl);
await new Promise((resolve,reject)=>{socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',reject,{once:true});});
let serial=0;
const pending=new Map(),exceptions=[],requests=[],samples=[],captures=[];
socket.addEventListener('message',event=>{
  const m=JSON.parse(event.data);
  if(m.id){const op=pending.get(m.id);pending.delete(m.id);m.error?op?.reject(new Error(JSON.stringify(m.error))):op?.resolve(m.result);}
  if(m.method==='Runtime.exceptionThrown')exceptions.push(m.params.exceptionDetails.exception?.description??m.params.exceptionDetails.text);
  if(m.method==='Network.requestWillBeSent'){
    const url=new URL(m.params.request.url);
    if(['http:','https:'].includes(url.protocol))requests.push({url:url.origin+url.pathname,type:m.params.type,method:m.params.request.method});
  }
});
const call=(method,params={})=>new Promise((resolve,reject)=>{const id=++serial;pending.set(id,{resolve,reject});socket.send(JSON.stringify({id,method,params}));});
async function evaluate(expression){const r=await call('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});if(r.exceptionDetails)throw new Error(JSON.stringify(r.exceptionDetails));return r.result.value;}
async function state(){return JSON.parse(await evaluate('window.utenLoadingProbe()'));}
async function settle(){await evaluate('new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))');}
async function waitFor(predicate,label){let last;for(let n=0;n<400;n++){last=await state();if(predicate(last))return last;await sleep(50);}fs.writeFileSync(evidenceRoot+'/wait-failure-'+label.replace(/[^a-z0-9]+/gi,'-')+'.json',JSON.stringify({label,last,exceptions},null,2));throw new Error('Timed out: '+label+'; last='+JSON.stringify(last));}
async function click(rect){if(!rect)throw new Error('Missing live hit rectangle');const x=rect[0]+rect[2]/2,y=rect[1]+rect[3]/2;await call('Input.dispatchMouseEvent',{type:'mousePressed',x,y,button:'left',clickCount:1});await call('Input.dispatchMouseEvent',{type:'mouseReleased',x,y,button:'left',clickCount:1});await settle();}
async function wheel(deltaY,x=600,y=450){await call('Input.dispatchMouseEvent',{type:'mouseWheel',x,y,deltaX:0,deltaY});await settle();}
function assertSnapshot(s,header,label){if(s.loadedRows!==36000||s.pageRequests!==0||s.placeholders!==0||s.actualLiveStates>400||s.headerElement!==header||s.bodyOwnerCount!==1||s.bodyPositionCount!==1)throw new Error(label+': '+JSON.stringify(s));samples.push({label,...s});}
async function screenshot(name){const p=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false});const file=evidenceRoot+'/'+name+'.png';fs.writeFileSync(file,Buffer.from(p.data,'base64'));captures.push(file);}
await call('Runtime.enable');await call('Page.enable');await call('Network.enable');
await call('Emulation.setDeviceMetricsOverride',{width:1440,height:900,deviceScaleFactor:1,mobile:false});
await call('Page.navigate',{url:`http://127.0.0.1:${owner.port}/`});
for(let n=0;n<400;n++){if(await evaluate('typeof window.utenLoadingProbe==="function"'))break;if(n===399)throw new Error('Probe unavailable');await sleep(50);}
let first=await waitFor(s=>s.loadedRows===36000&&s.maximumScroll>100000&&s.headerElement&&s.checkboxRects.length>3&&s.bodyOwnerCount===1&&s.bodyPositionCount===1,'anonymous full snapshot');
if(first.equalDuplicateOccurrences!==3||first.actualStateMounts>400)throw new Error('Equal anonymous occurrences dropped or dataset mounted: '+JSON.stringify(first));
await click(first.checkboxRects[1]);
let selected=await waitFor(s=>s.selectedOutputIds===1&&s.checkedMountedBoxes>=3,'equal-content output selection');
await click(selected.toolbarRect);
const duplicateOutput=await waitFor(s=>s.toolbarTaps===1,'real toolbar frozen selection');
if(duplicateOutput.capturedRawRows.length!==1||duplicateOutput.capturedRawRows[0].code!=='Equal duplicate')throw new Error('Output content identity changed: '+JSON.stringify(duplicateOutput));
await click(duplicateOutput.checkboxRects[1]);
first=await waitFor(s=>s.selectedOutputIds===0,'clear output selection');
const requestsBeforeScroll=requests.length;
for(const [index,delta] of [50000,50000,-100000,2000000,-2000000,900000,-900000].entries()){
  await wheel(delta);await sleep(120);assertSnapshot(await state(),first.headerElement,'jump-'+index);
}
for(let n=0;n<55;n++){await wheel(1300);assertSnapshot(await state(),first.headerElement,'continuous-frame-'+n);}
for(const width of [1440,720]){
  await call('Emulation.setDeviceMetricsOverride',{width,height:900,deviceScaleFactor:1,mobile:false});await settle();await sleep(160);
  const resize=await state();
  await wheel(5000000,Math.min(600,width-100));await sleep(160);
  const tail=await state();assertSnapshot(tail,resize.headerElement,'tail-'+width);
  if(tail.maximumScroll-tail.scrollPixels>2)throw new Error('Real wheel failed to reach tail '+width);
  await screenshot('web-tail-'+width);
  await wheel(-5000000,Math.min(600,width-100));await sleep(160);
  const top=await state();assertSnapshot(top,resize.headerElement,'top-'+width);
  if(top.scrollPixels>2)throw new Error('Real wheel failed to return top '+width);
  await screenshot('web-top-'+width);
}
if(!samples.some(s=>s.scrollPixels>1000))throw new Error('No real scrolling');
if(Math.max(...samples.map(s=>s.actualStateMounts))>6500)throw new Error('Actual State mounts exceed the visited viewport budget');
await call('Emulation.setDeviceMetricsOverride',{width:1440,height:900,deviceScaleFactor:1,mobile:false});await settle();await sleep(160);
await evaluate('window.utenLoadingAction("lineIds")');
const line=await waitFor(s=>s.mode==='line-identities'&&s.loadedRows===36000&&s.selectedOutputIds===0,'line identity replacement');
if(line.lineMapKeyReads!==0)throw new Error('Line identity enumerated raw Map keys');
await click(line.checkboxRects[1]);
const lineSelected=await waitFor(s=>s.selectedOutputIds===1,'line selection');await click(lineSelected.toolbarRect);
const lineOutput=await waitFor(s=>s.toolbarTaps===2,'line toolbar capture');
if(JSON.stringify(lineOutput.capturedRawRows)!==JSON.stringify([{'__lineId':'line-0'}])||lineOutput.lineMapKeyReads!==0)throw new Error('Line output fast path changed: '+JSON.stringify(lineOutput));

// Finish the real selection lifecycle before replacing the fixture source.
await click(lineOutput.checkboxRects[1]);
await waitFor(s=>s.selectedOutputIds===0,'clear line selection before fixture source replacement');
const inputSamples=[];
const key=async(key,code,virtual,modifiers=0)=>{await call('Input.dispatchKeyEvent',{type:'keyDown',key,code,windowsVirtualKeyCode:virtual,modifiers});await call('Input.dispatchKeyEvent',{type:'keyUp',key,code,windowsVirtualKeyCode:virtual,modifiers});};
const editor=s=>(s.cells??[]).find(c=>c.value==='ROW-00000');
async function measuredEdge(delta,x){for(let hop=0;hop<8;hop++){await wheel(delta,x);await sleep(160);const s=await state();if(delta>0?s.maximumScroll-s.scrollPixels<=2:s.scrollPixels<=2)return s;}throw new Error('Measured edge did not converge after eight real wheel events');}
for(const count of [200,20000]){
  await evaluate(`window.utenLoadingAction("rows:${count}")`);
  let current=await waitFor(s=>s.mode===`complete-${count}`&&s.loadedRows===count&&editor(s)?.rect&&s.windowViewport>0,'complete editable '+count);
  const draft='未提交原文 0.0001';await click(editor(current).rect);await key('a','KeyA',65,2);await call('Input.insertText',{text:draft});await key('Home','Home',36);for(let n=0;n<4;n++)await key('ArrowRight','ArrowRight',39,8);await settle();
  current=await waitFor(s=>editor(s)?.text===draft&&editor(s)?.focus&&editor(s)?.selection[0]!==editor(s)?.selection[1],'native text and keyboard selection');
  const original=editor(current);const header=current.headerElement;
  const assertEditor=(s,label)=>{const cell=editor(s);if(s.loadedRows!==count||s.pageRequests!==0||s.placeholders!==0||s.bodyOwnerCount!==1||s.bodyPositionCount!==1||s.headerElement!==header||!cell||cell.text!==draft||cell.identity!==original.identity||JSON.stringify(cell.selection)!==JSON.stringify(original.selection)||!cell.focus)throw new Error(label+': '+JSON.stringify(s));inputSamples.push({count,label,live:s.actualLiveStates,mounts:s.actualStateMounts,windowViewport:s.windowViewport,estimatedRowExtent:s.estimatedRowExtent,editor:cell});};
  for(const width of [1440,390]){
    await call('Emulation.setDeviceMetricsOverride',{width,height:900,deviceScaleFactor:1,mobile:false});await settle();await sleep(160);current=await state();assertEditor(current,'resize-'+width);
    const before=current.actualStateMounts;const tail=await measuredEdge(5000000,Math.min(600,width-70));assertEditor(tail,'tail-'+width);if(tail.maximumScroll-tail.scrollPixels>2||tail.actualStateMounts-before>=80)throw new Error('Unbounded far jump '+count+': '+JSON.stringify({before,tail}));await screenshot(`editable-${count}-tail-${width}`);
    const top=await measuredEdge(-5000000,Math.min(600,width-70));assertEditor(top,'top-'+width);if(top.scrollPixels>2)throw new Error('Input did not return to top');await screenshot(`editable-${count}-top-${width}`);
  }

}


const windowTarget=pages.find(p=>p.type==='page').id;
const ownedWindow=await call('Browser.getWindowForTarget',{targetId:windowTarget});
fs.writeFileSync(evidenceRoot+'/window-progress.json',JSON.stringify({phase:'before-minimize',ownedWindow,inputSamples},null,2));
await call('Browser.setWindowBounds',{windowId:ownedWindow.windowId,bounds:{windowState:'minimized'}});
const minimized=await call('Browser.getWindowBounds',{windowId:ownedWindow.windowId});
if(minimized.bounds.windowState!=='minimized')throw new Error('Owned browser did not actually minimize: '+JSON.stringify(minimized));
await call('Browser.setWindowBounds',{windowId:ownedWindow.windowId,bounds:{windowState:'normal'}});
await call('Page.bringToFront');await settle();
const resumed=await state();const resumedEditor=editor(resumed);const prior=inputSamples.at(-1).editor;
if(!resumedEditor||resumedEditor.identity!==prior.identity||resumedEditor.text!==prior.text||JSON.stringify(resumedEditor.selection)!==JSON.stringify(prior.selection)||!resumedEditor.focus||resumed.placeholders!==0||resumed.pageRequests!==0)throw new Error('Owned window restore lost editor state: '+JSON.stringify(resumed));
const restored=await call('Browser.getWindowBounds',{windowId:ownedWindow.windowId});
fs.writeFileSync(evidenceRoot+'/window-progress.json',JSON.stringify({phase:'verified',ownedWindow,minimized,restored,resumedEditor,inputSamples},null,2));

const scrollRequests=requests.slice(requestsBeforeScroll);
const isDataRequest=r=>{const p=new URL(r.url).pathname;const asset=p.startsWith('/assets/')||p.startsWith('/canvaskit/')||p.startsWith('/fallback_fonts/')||/\.(?:js|wasm|ttf|otf|woff2?|png|webp|svg|ico)$/.test(p);return p==='/api'||p.startsWith('/api/')||((r.type==='XHR'||r.type==='Fetch')&&!asset);};
const scrollDataRequests=scrollRequests.filter(isDataRequest);
const allDataRequests=requests.filter(isDataRequest);
if(exceptions.length||scrollDataRequests.length)throw new Error('Browser exceptions/data requests: '+JSON.stringify({exceptions,scrollDataRequests}));
if(allDataRequests.length)throw new Error('Business data requests during initial render or toolbar: '+JSON.stringify(allDataRequests));
const receipt={result:'PASS',runtime:'Flutter release JavaScript/CanvasKit in actual headless Chrome',datasetRows:36000,defaultBounded:true,businessIdentityCallbacks:false,equalMapOccurrences:3,duplicateOutput,lineOutput,wheelSamples:samples,continuousFrames:55,actualMaximumLiveStates:Math.max(...samples.map(s=>s.actualLiveStates)),actualCumulativeStateMounts:Math.max(...samples.map(s=>s.actualStateMounts)),pageRequests:0,browserExceptions:exceptions,scrollNetworkRequests:scrollRequests,scrollDataRequests,fixtureOnly:true,companyUat:false,screenshots:captures};
receipt.editableInputSamples=inputSamples;receipt.editableDatasets=[200,20000];receipt.browserWindowRestored=true;receipt.experimentalPageFreezeVerified=false;receipt.nativeWindowsRestoreVerified=false;receipt.imeCompositionVerified=false;
receipt.allNetworkRequests=requests;receipt.allDataRequests=allDataRequests;receipt.allBusinessHttpRequests=allDataRequests.length;
fs.writeFileSync(evidenceRoot+'/web-continuous-receipt.json',JSON.stringify(receipt,null,2));
console.log(JSON.stringify({result:receipt.result,samples:samples.length,continuousFrames:55,actualMaximumLiveStates:receipt.actualMaximumLiveStates,actualCumulativeStateMounts:receipt.actualCumulativeStateMounts,screenshots:captures}));socket.close();
