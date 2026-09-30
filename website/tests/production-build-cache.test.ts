import assert from 'node:assert/strict';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import nextConfig from '../next.config.mjs';

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const configure = nextConfig.webpack;
assert.ok(configure);

test('production rebuilds bundles while preserving the next-intl request alias', () => {
  for (const isServer of [false, true]) {
    const result = configure({
      context: projectRoot,
      cache: { type: 'filesystem', version: 'fixture' },
      resolve: { alias: {} },
    }, { dev: false, isServer } as Parameters<typeof configure>[1]);
    assert.equal(result.cache, false);
    assert.equal(result.resolve.alias['next-intl/config'], path.join(projectRoot, 'i18n/request.ts'));
  }
});

test('development retains incremental filesystem caching and the i18n alias', () => {
  const cache = { type: 'filesystem' as const, version: 'fixture' };
  const result = configure({ context: projectRoot, cache, resolve: { alias: {} } },
    { dev: true, isServer: false } as Parameters<typeof configure>[1]);
  assert.equal(result.cache, cache);
  assert.equal(result.resolve.alias['next-intl/config'], path.join(projectRoot, 'i18n/request.ts'));
});
