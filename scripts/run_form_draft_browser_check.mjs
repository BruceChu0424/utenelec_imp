import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';

const [compiledPath, chromePath] = process.argv.slice(2);
if (!compiledPath || !chromePath) throw new Error('Pass compiled JS path and Chrome executable path.');
const compiled = fs.readFileSync(path.resolve(compiledPath));
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'uten-draft-browser-'));
const namespace = `browser-smoke-${randomUUID()}`;
const results = [];
let resolvePhase;
let chrome;
let chromeErrors = '';
const server = http.createServer((req, res) => {
  if ((req.url === '/result' || req.url === '/progress') && req.method === 'POST') {
    const chunks = [];
    req.on('data', chunk => chunks.push(chunk));
    req.on('end', () => {
      const result = JSON.parse(Buffer.concat(chunks).toString());
      res.writeHead(200).end('ok');
      if (req.url === '/result') resolvePhase?.(result);
      else process.stdout.write(`${JSON.stringify(result)}\n`);
    });
  } else if (req.url === '/draft_storage.js') {
    res.writeHead(200, {'Content-Type': 'text/javascript'}).end(compiled);
  } else {
    res.writeHead(200, {'Content-Type': 'text/html; charset=utf-8'}).end(
      '<!doctype html><meta charset="utf-8"><body>Running browser storage checks<script src="/draft_storage.js" defer></script></body>',
    );
  }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const port = server.address().port;
async function stopChrome() {
  if (!chrome) return;
  const current = chrome;
  const debuggingFile = path.join(profile, 'DevToolsActivePort');
  if (fs.existsSync(debuggingFile) && current.exitCode === null) {
    const [debugPort, browserPath] = fs.readFileSync(debuggingFile, 'utf8').trim().split(/\r?\n/);
    await new Promise(resolve => {
      const timer = setTimeout(resolve, 5000);
      const socket = new WebSocket(`ws://127.0.0.1:${debugPort}${browserPath}`);
      socket.onopen = () => socket.send(JSON.stringify({id: 1, method: 'Browser.close'}));
      socket.onclose = () => { clearTimeout(timer); resolve(); };
      socket.onerror = () => { clearTimeout(timer); resolve(); };
    });
    if (current.exitCode === null) {
      await new Promise(resolve => {
        const timer = setTimeout(resolve, 5000);
        current.once('exit', () => { clearTimeout(timer); resolve(); });
      });
    }
  }
  if (current.exitCode === null && process.platform === 'win32') {
    await new Promise(resolve => {
      const kill = spawn('taskkill', ['/PID', String(current.pid), '/T', '/F'], {windowsHide: true, stdio: 'ignore'});
      kill.once('exit', resolve);
    });
  } else if (current.exitCode === null) {
    current.kill('SIGKILL');
  }
  chrome = null;
  // Windows may release the profile's process-singleton handle just after
  // browser shutdown returns. Never remove or bypass that lock.
  if (process.platform === 'win32') await new Promise(resolve => setTimeout(resolve, 1000));
}
try {
  for (const phase of ['write', 'read']) {
    const result = await new Promise((resolve, reject) => {
      chromeErrors = '';
      const timer = setTimeout(() => reject(new Error(`Chrome ${phase} phase timed out: ${chromeErrors}`)), 45000);
      resolvePhase = result => { clearTimeout(timer); resolve(result); };
      chrome = spawn(chromePath, ['--headless=new', '--disable-gpu', '--no-first-run', '--enable-logging=stderr', '--remote-debugging-port=0',
        '--no-default-browser-check', `--user-data-dir=${profile}`,
        `http://127.0.0.1:${port}/?phase=${phase}&namespace=${namespace}`],
        {windowsHide: true, stdio: ['ignore', 'ignore', 'pipe']});
      chrome.stderr.on('data', bytes => { chromeErrors = (chromeErrors + bytes.toString()).slice(-4000); });
      chrome.once('error', error => { clearTimeout(timer); reject(error); });
      chrome.once('exit', code => {
        if (code && chromeErrors.includes('ProcessSingleton')) {
          clearTimeout(timer);
          reject(new Error(`Chrome profile still locked after process shutdown: ${chromeErrors}`));
        }
      });
    });
    results.push(result);
    process.stdout.write(`${JSON.stringify(result)}\n`);
    await stopChrome();
    if (result.status !== 'passed') throw new Error(JSON.stringify(result));
  }
  const report = {status: 'passed', browserProcessRestarted: true, results};
  const outputPath = path.join(path.dirname(path.resolve(compiledPath)), 'result.json');
  fs.writeFileSync(outputPath, JSON.stringify(report, null, 2));
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
} finally {
  await stopChrome();
  await new Promise(resolve => server.close(resolve));
  const resolvedProfile = path.resolve(profile);
  const allowedPrefix = path.join(path.resolve(os.tmpdir()), 'uten-draft-browser-');
  if (!resolvedProfile.startsWith(allowedPrefix)) throw new Error('Refusing out-of-scope profile cleanup.');
  fs.rmSync(resolvedProfile, {recursive: true, force: true, maxRetries: 5, retryDelay: 200});
}
