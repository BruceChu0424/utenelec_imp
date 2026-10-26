const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, 'maintenance.js'), 'utf8');
const settle = async () => {
  await new Promise(setImmediate);
  await new Promise(setImmediate);
};
const snapshot = (state, extra = {}) => ({
  schemaVersion: 1, state, serverTime: '2026-10-26T22:00:00Z',
  noticeId: '12345678-1234-1234-1234-123456789abc',
  targetVersion: 'v2.5.32', retryAfterSeconds: 10, ...extra,
});
const response = (body, extra = {}) => ({
  ok: true, headers: { get: () => 'application/json' },
  json: async () => body, ...extra,
});

async function openPage({ replies = [], pathname = '/sales/orders/123', hidden = false } = {}) {
  const elements = new Map();
  const listeners = new Map();
  const timers = new Map();
  const requests = [];
  const navigation = [];
  let timerId = 0;
  const classes = new Set();
  const node = (id) => {
    if (!elements.has(id)) elements.set(id, {
      textContent: '', hidden: false, disabled: false,
      classList: { toggle() {}, add() {}, remove() {} },
      addEventListener(name, callback) { listeners.set(`${id}:${name}`, callback); },
    });
    return elements.get(id);
  };
  const document = {
    hidden, documentElement: {},
    body: { classList: { toggle(name, active) { if (active) classes.add(name); else classes.delete(name); } } },
    getElementById: node,
    addEventListener(name, callback) { listeners.set(name, callback); },
  };
  vm.runInNewContext(source, {
    navigator: { language: 'zh-CN' }, document, AbortController,
    window: { location: {
      pathname,
      reload() { navigation.push({ kind: 'reload', pathname }); },
      replace(target) { navigation.push({ kind: 'replace', target }); },
    } },
    setTimeout(callback, delay) { const id = ++timerId; timers.set(id, { callback, delay }); return id; },
    clearTimeout(id) { timers.delete(id); },
    fetch: async (url, options) => {
      requests.push({ url, options });
      const next = replies.shift();
      if (next instanceof Error) throw next;
      if (next === undefined) throw new Error('No response');
      return next;
    },
  }, { filename: 'maintenance.js' });
  await settle();
  return {
    node, document, classes, requests, navigation, timers,
    async click() { await listeners.get('retry:click')(); await settle(); },
    async visibility(value) { document.hidden = value; listeners.get('visibilitychange')(); await settle(); },
  };
}

test('new browser entry shows maintenance, uses no credentials and preserves its deep link', async () => {
  const page = await openPage({ replies: [response(snapshot('updating'))] });
  assert.match(page.node('heading').textContent, /服务器正在更新/);
  assert.equal(page.node('version').textContent, '目标版本 v2.5.32');
  assert.equal(page.requests[0].url, '/api/system/maintenance');
  assert.equal(page.requests[0].options.credentials, 'omit');
  assert.equal(page.requests[0].options.cache, 'no-store');
  assert.equal(page.requests[0].options.redirect, 'error');
  assert.equal(page.navigation.length, 0);
});

test('a network failure keeps the page and permits manual recovery without replaying work', async () => {
  const page = await openPage({ replies: [new Error('offline'), response(snapshot('recovery_required'))] });
  assert.match(page.node('status').textContent, /暂时无法读取/);
  assert.equal(page.node('retry').disabled, false);
  await page.click();
  assert.equal(page.classes.has('recovery'), true);
  assert.equal(page.navigation.length, 0);
  assert.equal(page.requests.every((request) => !request.options.method || request.options.method === 'GET'), true);
});

test('scheduled page shows the published start time and does not pretend updating has begun', async () => {
  const page = await openPage({ replies: [response(snapshot('scheduled', { startsAt: '2026-10-26T22:10:00Z' }))] });
  assert.match(page.node('heading').textContent, /即将更新/);
  assert.equal(page.node('step-notice').className, 'current');
  assert.equal(page.node('step-update').className, '');
  assert.equal(page.node('start').hidden, false);
  assert.match(page.node('start').textContent, /北京时间/);
  assert.match(page.node('start').textContent, /06:10/);
  assert.equal(page.navigation.length, 0);
});

test('cleared marker alone never opens an unhealthy application', async () => {
  const page = await openPage({ replies: [response(snapshot('available')), response({ status: 'DOWN' })] });
  assert.equal(page.requests[1].url, '/actuator/health/readiness');
  assert.equal(page.navigation.length, 0);
  assert.equal(page.timers.size, 1);
});

test('recovery reloads the original business URL only after available and readiness UP', async () => {
  const page = await openPage({ replies: [response(snapshot('available')), response({ status: 'UP' })] });
  assert.deepEqual(page.navigation, [{ kind: 'reload', pathname: '/sales/orders/123' }]);
  assert.equal(page.timers.size, 0);
  await page.click();
  assert.equal(page.navigation.length, 1);
});

test('opening the standalone maintenance URL returns to the app when healthy', async () => {
  const page = await openPage({ pathname: '/maintenance.html', replies: [response(snapshot('available')), response({ status: 'UP' })] });
  assert.deepEqual(page.navigation, [{ kind: 'replace', target: '/' }]);
});

test('an error document or unknown state cannot authorize recovery', async () => {
  for (const reply of [
    response(snapshot('available'), { ok: false }),
    response(snapshot('available'), { headers: { get: () => 'text/html' } }),
    response(snapshot('unknown')),
    response({ ...snapshot('available'), schemaVersion: 2 }),
  ]) {
    const page = await openPage({ replies: [reply] });
    assert.equal(page.navigation.length, 0);
    assert.equal(page.requests.length, 1);
    assert.match(page.node('status').textContent, /暂时无法读取/);
  }
});

test('hidden tabs do not poll, resume promptly and clamp server polling intervals', async () => {
  const page = await openPage({ hidden: true, replies: [response(snapshot('updating', { retryAfterSeconds: 1 }))] });
  assert.equal(page.requests.length, 0);
  await page.visibility(false);
  assert.equal(page.requests.length, 1);
  assert.equal([...page.timers.values()][0].delay, 5000);
  await page.visibility(true);
  assert.equal(page.timers.size, 0);
});

test('maintenance document works under existing strict script policy without remote assets', () => {
  const html = fs.readFileSync(path.join(__dirname, 'maintenance.html'), 'utf8');
  assert.match(html, /<script src="\/maintenance\.js" defer><\/script>/);
  assert.match(html, /href="\/maintenance\.css"/);
  assert.doesNotMatch(html, /<style\b|\son\w+=|<script(?![^>]*\bsrc=)|https?:\/\//i);
});
