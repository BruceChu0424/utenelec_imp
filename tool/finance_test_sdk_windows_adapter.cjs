// Private Flutter headless-test plumbing only. Never changes product, SDK or assertions.
const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
async function run(options) {
  const debugPort=Number(options['debug-port']);
  const origin=new URL(options['test-origin']);
  const canvasRoot=path.resolve(options['canvas-kit']);
  // Flutter's static test-host route also matches product *_host.dart.js
  // modules. An explicitly owned compiler manifest lets the adapter return
  // the original, unmodified module bytes instead of the test-host bootstrap.
  const manifestPath=options['compiled-manifest'];
  const codePath=options['compiled-code'];
  if(Boolean(manifestPath)!==Boolean(codePath))throw Error('Both own compiled manifest and code are required');
  const compiledManifest=manifestPath?JSON.parse(await fs.readFile(manifestPath,'utf8')):null;
  const compiledCode=codePath?await fs.readFile(codePath):null;
  if(!Number.isInteger(debugPort)||debugPort<1024||debugPort>65535||origin.protocol!=='http:'||
    !['localhost','127.0.0.1'].includes(origin.hostname))throw Error('Only an explicitly owned local test browser is allowed');
  const targets = await (await fetch(`http://127.0.0.1:${debugPort}/json/list`)).json();
  if(options.initialHostUrl) {
    const host=new URL(options.initialHostUrl);
    if(host.origin!==origin.origin || host.pathname!=='/static/index.html' || !host.searchParams.has('managerUrl')) {
      throw Error('Only the original local Flutter test host may be opened');
    }
  }
  const target=targets.find(value=>value.type==='page' && (options.initialHostUrl
    ?value.url==='about:blank'
    :value.title==='Flutter Test Browser Host' && value.url.startsWith(`${origin.origin}/static/index.html?managerUrl=`)));
  if(!target)throw Error('The explicitly owned Flutter test page is unavailable');
  const registry = await (await fetch(`${origin.origin}/main.dart.js`)).text();
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
  const pending = new Map();
  let id = 0;
  function call(method, params = {}) {
    const next = ++id;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { pending.delete(next); reject(Error(`${method} timed out`)); }, 15000);
      pending.set(next, value => { clearTimeout(timer); value.error ? reject(Error(JSON.stringify(value.error))) : resolve(value.result); });
      ws.send(JSON.stringify({ id: next, method, params }));
    });
  }
  async function intercept(event) {
    const url = new URL(event.request.url);
    if(compiledManifest&&url.origin===origin.origin&&url.pathname==='/packages/uten_imp/components/layout/uten_page_scrollbar_host.dart.js') {
      const modulePath=url.pathname.replace(/\.dart\.js$/,'.dart.lib.js');
      const offsets=compiledManifest[modulePath]?.code;
      if(!Array.isArray(offsets)||offsets.length!==2||offsets[0]<0||offsets[1]>compiledCode.length)throw Error('The intercepted module is absent from this compiler output');
      const bytes=compiledCode.subarray(offsets[0],offsets[1]);
      const source=bytes.toString('utf8');
      if(!source.includes('// Module: packages/uten_imp/components/layout/uten_page_scrollbar_host.dart')||!source.includes('\ndefine(')||!source.includes('uten_imp__components__layout__uten_page_scrollbar_host'))throw Error('Expected the exact page-scrollbar AMD module');
      await call('Fetch.fulfillRequest',{requestId:event.requestId,responseCode:200,
        responseHeaders:[{name:'Content-Type',value:'text/javascript'}],body:bytes.toString('base64')});
      console.log(JSON.stringify({adapted:'same-compile-module-host-route',module:modulePath,bytes:bytes.length,sha256:crypto.createHash('sha256').update(bytes).digest('hex')}));
      return;
    }
    if (url.origin !== origin.origin) throw Error('Interception escaped its declared test origin');
    if (url.pathname.startsWith('/canvaskit/')) {
      const relative = decodeURIComponent(url.pathname.slice('/canvaskit/'.length));
      const candidate = path.resolve(canvasRoot, relative);
      if (!candidate.startsWith(canvasRoot + path.sep)) throw Error('CanvasKit path escaped the declared SDK directory');
      const bytes = await fs.readFile(candidate);
      const type = candidate.endsWith('.wasm') ? 'application/wasm' : candidate.endsWith('.js') ? 'text/javascript' : 'application/octet-stream';
      await call('Fetch.fulfillRequest', { requestId: event.requestId, responseCode: 200,
        responseHeaders: [{ name: 'Content-Type', value: type }], body: bytes.toString('base64') });
      console.log(JSON.stringify({ adapted: 'same-sdk-local-canvaskit', resource: url.pathname, bytes: bytes.length }));
      return;
    }
    if (event.responseStatusCode === 200 && url.pathname.endsWith('.html')) {
      const response = await call('Fetch.getResponseBody', { requestId: event.requestId });
      const html = response.base64Encoded ? Buffer.from(response.body, 'base64').toString('utf8') : response.body;
      if (/window\.testSelector\s*=/.test(html)) {
        const selector = url.pathname.slice(1).replace(/\.html$/, '.dart');
        if (!registry.includes(JSON.stringify(selector))) throw Error('The requested selector is not in the unmodified compiled test registry');
        const replaced = html.replace(/window\.testSelector\s*=\s*"[^"]*"\s*;/,
          `window.testSelector = ${JSON.stringify(selector)};`);
        if (replaced === html && !html.includes(`window.testSelector = ${JSON.stringify(selector)}`)) throw Error('Unrecognized Flutter test selector markup');
        const headers = (event.responseHeaders ?? []).filter(header =>
          !['content-length', 'content-encoding', 'transfer-encoding'].includes(header.name.toLowerCase()));
        await call('Fetch.fulfillRequest', { requestId: event.requestId, responseCode: 200,
          responseHeaders: headers, body: Buffer.from(replaced, 'utf8').toString('base64') });
        console.log(JSON.stringify({ adapted: 'json-escaped-test-selector', selector }));
        return;
      }
    }
    await call('Fetch.continueRequest', { requestId: event.requestId });
  }
  ws.onmessage = async event => {
    const message = JSON.parse(event.data);
    if (message.id) { pending.get(message.id)?.(message); pending.delete(message.id); return; }
    if (message.method === 'Fetch.requestPaused') {
      try { await intercept(message.params); }
      catch (error) {
        console.error(error);
        await call('Fetch.failRequest', { requestId: message.params.requestId, errorReason: 'Failed' }).catch(() => {});
        process.exitCode = 1;
      }
    }
  };
  await call('Network.enable');
  await call('Network.setCacheDisabled', { cacheDisabled: true });
  await call('Fetch.enable', { patterns: [
    { urlPattern: `${origin.origin}/canvaskit/*`, requestStage: 'Request' },
    { urlPattern: `${origin.origin}/*.html*`, requestStage: 'Response' },
    ...(compiledManifest?[{urlPattern:`${origin.origin}/packages/uten_imp/components/layout/uten_page_scrollbar_host.dart.js`,requestStage:'Request'}]:[]),
  ] });
  if(options.initialHostUrl) {
    await call('Page.navigate',{url:options.initialHostUrl});
    console.log(JSON.stringify({started:'original-flutter-test-host-after-sdk-adapter',origin:origin.origin}));
  } else {
    const tree = await call('Page.getFrameTree');
    const frame = tree.frameTree.childFrames?.find(value => value.frame.url.startsWith(origin.origin) &&
      value.frame.url.includes('_test.html'))?.frame;
    if (!frame) throw Error('Expected a not-started test iframe');
    await call('Page.navigate', { frameId: frame.id, url: frame.url });
    console.log(JSON.stringify({ reset: 'not-started-test-iframe', origin: origin.origin }));
  }
  await new Promise(resolve => { ws.onclose = resolve; ws.onerror = resolve; });
}
module.exports={run};
if(require.main===module) {
  const options=Object.fromEntries(process.argv.slice(2).map(value=>{
    const index=value.indexOf('=');if(!value.startsWith('--')||index<3)throw Error('Expected --name=value');
    return [value.slice(2,index),value.slice(index+1)];
  }));
  run(options).catch(error=>{console.error(error);process.exitCode=1;});
}
