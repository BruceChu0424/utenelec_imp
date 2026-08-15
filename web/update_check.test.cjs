const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, 'update_check.js'), 'utf8');

async function runChecker({ baseline, remote }) {
  let banner;
  let fetchCount = 0;
  const storage = new Map();

  function element() {
    return {
      attributes: new Map(),
      children: [],
      listeners: new Map(),
      append(...children) { this.children.push(...children); },
      addEventListener(name, listener) { this.listeners.set(name, listener); },
      setAttribute(name, value) { this.attributes.set(name, value); },
      remove() { if (banner === this) banner = undefined; },
    };
  }

  const document = {
    baseURI: 'https://erp.example.internal/',
    visibilityState: 'visible',
    body: {
      append(node) { banner = node; },
    },
    addEventListener() {},
    createElement: element,
    getElementById(id) { return banner?.id === id ? banner : undefined; },
    querySelector(selector) {
      if (selector !== 'meta[name="uten-release-version"]') return undefined;
      return { getAttribute: () => baseline };
    },
  };

  const window = {
    addEventListener() {},
    location: { reload() {} },
    sessionStorage: {
      getItem(key) { return storage.get(key) ?? null; },
      setItem(key, value) { storage.set(key, value); },
    },
    setInterval() {},
    setTimeout(callback) { callback(); },
  };

  async function fetch() {
    fetchCount += 1;
    return {
      ok: true,
      async json() { return remote; },
    };
  }

  vm.runInNewContext(source, {
    URL,
    document,
    fetch,
    window,
  }, { filename: 'update_check.js' });
  await new Promise((resolve) => setImmediate(resolve));
  await new Promise((resolve) => setImmediate(resolve));
  return { banner, fetchCount };
}

function metadata(version, sequence, commit = 'a'.repeat(40)) {
  return {
    commitSha: commit,
    product: 'uten-imp',
    releaseSequence: sequence,
    schemaVersion: 1,
    version,
  };
}

test('shows a banner when only signed application release metadata changes', async () => {
  const result = await runChecker({
    baseline: 'v2026.08.11-1',
    remote: metadata('v2026.08.11-2', 20260811002),
  });

  assert.equal(result.fetchCount, 1);
  assert.equal(result.banner?.id, 'uten-web-update-banner');
});

test('does not show a banner for the page release itself', async () => {
  const result = await runChecker({
    baseline: 'v2026.08.11-2',
    remote: metadata('v2026.08.11-2', 20260811002),
  });

  assert.equal(result.fetchCount, 1);
  assert.equal(result.banner, undefined);
});

test('an unstamped development page never polls or prompts', async () => {
  const result = await runChecker({
    baseline: '__UTEN_RELEASE_VERSION__',
    remote: metadata('v2026.08.11-2', 20260811002),
  });

  assert.equal(result.fetchCount, 0);
  assert.equal(result.banner, undefined);
});

test('rejects malformed or unsigned-looking metadata', async () => {
  const result = await runChecker({
    baseline: 'v2026.08.11-1',
    remote: { version: 'v2026.08.11-2' },
  });

  assert.equal(result.fetchCount, 1);
  assert.equal(result.banner, undefined);
});
