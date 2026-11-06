import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(process.argv[2] ?? 'build/loading-web');
const evidenceRoot = path.resolve(process.argv[3] ?? 'build/loading-validation');
const kit = path.resolve('D:/Software/Flutter/flutter/bin/cache/flutter_web_sdk/canvaskit');
const server = http.createServer((request, response) => {
  const url = new URL(request.url, 'http://127.0.0.1');
  const base = url.pathname.startsWith('/canvaskit/') ? kit : root;
  const relative = base === kit ? url.pathname.slice('/canvaskit'.length) : url.pathname;
  const file = path.resolve(base, '.' + (relative === '/' ? '/index.html' : decodeURIComponent(relative)));
  if (!file.startsWith(base + path.sep)) { response.writeHead(403).end(); return; }
  try {
    const body = fs.readFileSync(file);
    const types = {'.js': 'text/javascript', '.html': 'text/html', '.json': 'application/json',
      '.wasm': 'application/wasm', '.ttf': 'font/ttf', '.otf': 'font/otf', '.png': 'image/png'};
    response.setHeader('Content-Type', types[path.extname(file)] ?? 'application/octet-stream');
    response.setHeader('Cache-Control', 'no-store');
    response.end(body);
  } catch { response.writeHead(404).end(); }
});
server.listen(0, '127.0.0.1', () => {
  const owner = {pid: process.pid, port: server.address().port, root, loopbackOnly: true};
  fs.mkdirSync(evidenceRoot, {recursive: true});
  fs.writeFileSync(path.join(evidenceRoot, 'web-server-owner.json'), JSON.stringify(owner, null, 2));
  console.log(JSON.stringify(owner));
});
