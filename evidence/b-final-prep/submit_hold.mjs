// Evidence-only transport gate for Root's existing real passthrough proxy.
// No API values, headers or request bytes are replaced; no credentials/body log.
import fs from 'node:fs';
import path from 'node:path';
const active = new Map();
const allowed = /^\/api\/production\/material-analyses\/[0-9a-f-]{36}\/aggregate-orders\/submit$/;

// Call before constructing http.request or req.pipe(upstream). Return true
// means this gate owns forwarding. privateDirectory is the proxy's own private/.
export function holdExactPost(req, res, pathname, privateDirectory, forward, metadataLog) {
  if (req.method !== 'POST' || !allowed.test(pathname)) return false;
  let gate = active.get(pathname);
  if (!gate) {
    const configPath = path.join(privateDirectory, 'fault.json');
    let config;
    try { config = JSON.parse(fs.readFileSync(configPath, 'utf8')); } catch { return false; }
    const option = config.holdNextPost;
    if (!option || option.path !== pathname) return false;
    if (!/^[a-zA-Z0-9_-]{1,80}$/.test(option.tag)) throw new Error('Invalid synthetic hold tag');
    const directory = path.join(privateDirectory, 'transport-holds', option.tag);
    fs.mkdirSync(directory, {recursive: true});
    const ready = path.join(directory, 'hold-ready.json');
    if (fs.existsSync(ready)) throw new Error('Preserve the previous transport gate; use a new tag');
    gate = {directory, started: Date.now(), requests: [], pathname};
    active.set(pathname, gate);
    // Consume once, preserving other existing transport faults.
    config.holdNextPost = null;
    fs.writeFileSync(configPath, JSON.stringify(config));
    fs.writeFileSync(ready, JSON.stringify({kind:'real-request-held-before-forwarding', path:pathname, method:'POST', startedAtUtc:new Date().toISOString()}), {flag:'wx'});
    gate.timer = setInterval(() => {
      const released = fs.existsSync(path.join(directory, 'release'));
      if (!released && Date.now() - gate.started < 40000) return;
      clearInterval(gate.timer);active.delete(pathname);
      for (const request of gate.requests) {
        metadataLog({path:pathname, method:'POST', transportHold:released?'released-unchanged':'timeout-no-forward', ms:Date.now()-gate.started});
        if (request.req.destroyed || request.res.destroyed) continue;
        if (released) {request.forward();request.req.socket.resume();} else {request.req.destroy();request.res.destroy();}
      }
    }, 50);
  }
  // IncomingMessage stays paused; Node's stream backpressure bounds the buffer.
  // The UI must still guard rapid repeats. Additional held duplicate requests
  // share the gate and are forwarded unchanged after the same legal mutation.
  if (gate.requests.length >= 4) { req.destroy();res.destroy();return true; }
  req.pause();req.socket.pause();gate.requests.push({req,res,forward});return true;
}
