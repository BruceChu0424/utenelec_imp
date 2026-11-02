// Serves only the compiled isolated contract, then closes its own browser/server.
import {createServer} from 'node:http';
import {readFile, writeFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import path from 'node:path';

const directory = path.resolve('build/category-web-contract');
const compiled = await readFile(path.join(directory, 'contract.js'));
const server = createServer((request, response) => {
  if (request.url === '/contract.js') {
    response.writeHead(200, {'Content-Type': 'text/javascript', 'Cache-Control': 'no-store'});
    response.end(compiled);
  } else if (request.url === '/') {
    response.writeHead(200, {'Content-Type': 'text/html; charset=utf-8'});
    response.end('<!doctype html><html><head><script defer src="/contract.js"></script></head><body>running</body></html>');
  } else {
    response.writeHead(404);
    response.end();
  }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
try {
  const chrome = process.env.CHROME_EXECUTABLE || 'C:/Program Files/Google/Chrome/Application/chrome.exe';
  const child = spawn(chrome, ['--headless=new', '--disable-gpu', '--no-first-run',
    `--user-data-dir=${path.join(directory, 'chrome-profile')}`,
    '--virtual-time-budget=10000', '--dump-dom', `http://127.0.0.1:${server.address().port}/`],
    {windowsHide: true, stdio: ['ignore', 'pipe', 'pipe']});
  let output = '', errors = '';
  child.stdout.on('data', chunk => { output += chunk; });
  child.stderr.on('data', chunk => { errors += chunk; });
  await new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('exit', code => code === 0 ? resolve() : reject(new Error(`Contract Chrome exited ${code}`)));
  });
  await writeFile(path.join(directory, 'dom.html'), output);
  await writeFile(path.join(directory, 'chrome.log'), errors);
  const body = output.match(/<body[^>]*>([\s\S]*?)<\/body>/)?.[1]?.trim();
  const result = JSON.parse(body);
  await writeFile(path.join(directory, 'result.json'), JSON.stringify({
    ...result, runtime: 'Actual headless Chrome, dart2js and Dio; no Flutter platform-test bootstrap',
    fullFlutterWebPageUat: false,
  }, null, 2) + '\n');
  if (!result.passed) throw new Error(result.error || 'Browser contract failed');
  process.stdout.write(JSON.stringify(result) + '\n');
} finally {
  await new Promise(resolve => server.close(resolve));
}
