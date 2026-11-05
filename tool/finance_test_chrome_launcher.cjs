// Entry point of the private Chrome launcher. argv crosses the PE boundary as Base64 JSON, never through a shell.
const fs=require('node:fs/promises');
const path=require('node:path');
const {spawn}=require('node:child_process');
const {run}=require('./finance_test_sdk_windows_adapter.cjs');
(async()=>{
  const args=JSON.parse(Buffer.from(process.argv[2],'base64').toString('utf8'));
  const ready=Buffer.from(process.argv[3],'base64').toString('utf8');
  if(!Array.isArray(args)||args.some(value=>typeof value!=='string'))throw Error('Invalid original Chrome arguments');
  const profile=args.find(value=>value.startsWith('--user-data-dir='));
  const port=args.find(value=>value.startsWith('--remote-debugging-port='));
  const host=args.find(value=>value.startsWith('http://localhost:')&&value.includes('/static/index.html?managerUrl='));
  if(!profile?.includes('flutter_tools_chrome_device')||!port||!host||!args.includes('--headless'))throw Error('Only a standard isolated Flutter headless test launch is supported');
  const limit=Date.now()+15000;
  for(;;){try{await fs.access(ready);break;}catch{if(Date.now()>limit)throw Error('Private process job not ready');await new Promise(resolve=>setTimeout(resolve,10));}}
  const chrome=spawn(process.env.UTEN_TEST_REAL_CHROME,args.map(value=>value===host?'about:blank':value),{windowsHide:true,stdio:'inherit'});
  let exited=false;chrome.on('exit',()=>{exited=true;});
  try {
    const debugPort=Number(port.split('=')[1]);
    for(;;){try{await fetch(`http://127.0.0.1:${debugPort}/json/list`);break;}catch{if(exited||Date.now()>limit)throw Error('Own headless Chrome did not start');await new Promise(resolve=>setTimeout(resolve,25));}}
    await run({'debug-port':debugPort,'test-origin':new URL(host).origin,
      'canvas-kit':process.env.UTEN_TEST_CANVASKIT,initialHostUrl:host});
  } finally {if(!exited)chrome.kill();}
})().catch(error=>{console.error(error);process.exitCode=1;});
