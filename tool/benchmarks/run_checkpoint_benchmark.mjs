// Standalone, loopback-only microbenchmark in a separate headless Chrome.
// Uses real browser clocks/timers (no virtual-time acceleration).
import fs from 'node:fs/promises';
import path from 'node:path';
import http from 'node:http';
import {spawn} from 'node:child_process';

const directory = path.resolve(process.argv[2] ?? 'tmp/table-performance-validation');
const chrome = process.argv[3] ?? 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const script = await fs.readFile(path.join(directory, 'checkpoint-bench.js'));
const profile = await fs.mkdtemp(path.join(directory, 'checkpoint-chrome-'));
const html = `<!doctype html><meta charset="utf-8"><title>Checkpoint microbenchmark</title>
<pre id="result">Running synthetic CPU/timer comparison</pre><script>
window.__checkpointResult=null;window.__checkpointError=null;
const originalLog=console.log.bind(console);console.log=(...args)=>{
 const line=args.join(' ');if(line.startsWith('CHECKPOINT_BENCH ')){
 window.__checkpointResult=JSON.parse(line.slice(17));
 document.getElementById('result').textContent=JSON.stringify(window.__checkpointResult);}
 originalLog(...args);};
window.addEventListener('error',e=>window.__checkpointError=e.message);
</script><script defer src="/checkpoint-bench.js"></script>`;
const server = http.createServer((request, response) => {
  if (request.url === '/') {
    response.writeHead(200, {'Content-Type':'text/html; charset=utf-8'}).end(html);
  } else if (request.url === '/checkpoint-bench.js') {
    response.writeHead(200, {'Content-Type':'application/javascript'}).end(script);
  } else response.writeHead(404).end();
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const url = `http://127.0.0.1:${server.address().port}/`;
const processHandle = spawn(chrome, [
  '--headless=new', '--remote-debugging-port=0', `--user-data-dir=${profile}`,
  '--no-first-run', '--disable-default-apps', '--disable-background-networking', url,
], {windowsHide:true, stdio:'ignore'});
let ws;
let command;
try {
  const deadline = Date.now() + 90000;
  const delay = () => new Promise(resolve => setTimeout(resolve, 150));
  let port;
  while (!port && Date.now() < deadline) {
    try {port = Number((await fs.readFile(path.join(profile, 'DevToolsActivePort'), 'utf8')).split('\n')[0]);}
    catch {await delay();}
  }
  if (!port) throw new Error('Chrome debugging endpoint was not ready');
  const version = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
  let page;
  while (!page && Date.now() < deadline) {
    page = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json())
      .find(value => value.type === 'page' && value.url === url);
    if (!page) await delay();
  }
  if (!page) throw new Error('Synthetic page was not created');
  ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {ws.onopen=resolve;ws.onerror=reject;});
  let id = 0;
  const pending = new Map();
  ws.onmessage = event => {
    const message = JSON.parse(event.data);
    if (message.id && pending.has(message.id)) {
      pending.get(message.id)(message);
      pending.delete(message.id);
    }
  };
  command = (method, params = {}) => new Promise(resolve => {
    const request = ++id;pending.set(request, resolve);
    ws.send(JSON.stringify({id:request,method,params}));
  });
  while (Date.now() < deadline) {
    const evaluated = await command('Runtime.evaluate', {
      expression:'JSON.stringify({result:window.__checkpointResult,error:window.__checkpointError,visibility:document.visibilityState})',
      returnByValue:true,
    });
    const value = JSON.parse(evaluated.result?.result?.value ?? '{}');
    if (value.error) throw new Error(value.error);
    if (value.result) {
      const output = {...value.result, browser:version.Browser, headless:true,
        realTimers:true, virtualTime:false, visibility:value.visibility};
      await fs.writeFile(path.join(directory, 'checkpoint-web-prototype.json'), JSON.stringify(output,null,2));
      console.log(JSON.stringify({browser:output.browser,visibility:output.visibility,medians:output.medians}));
      break;
    }
    await delay();
  }
  if (Date.now() >= deadline) throw new Error('Microbenchmark did not finish within 90 seconds');
} finally {
  if (command) {
    command('Browser.close');
    await new Promise(resolve => setTimeout(resolve, 250));
  }
  ws?.close();
  processHandle.kill();
  await new Promise(resolve => server.close(resolve));
  // Profile is retained with the evidence directory; no recursive deletion.
}
