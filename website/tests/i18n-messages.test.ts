import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';

const LOCALES = ['en', 'zh', 'ar', 'de', 'es', 'fr', 'ja', 'ko', 'pt', 'ru'] as const;

function flatten(value: unknown, prefix = '', result: Record<string, unknown> = {}) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return result;

  for (const [key, child] of Object.entries(value)) {
    const fullKey = prefix ? `${prefix}.${key}` : key;
    if (child && typeof child === 'object' && !Array.isArray(child)) {
      flatten(child, fullKey, result);
    } else {
      result[fullKey] = child;
    }
  }

  return result;
}

function placeholders(value: unknown) {
  return [...String(value).matchAll(/\{([A-Za-z][A-Za-z0-9_]*)\}/g)]
    .map((match) => match[1])
    .sort();
}

function readMessages(locale: (typeof LOCALES)[number]) {
  const file = path.join(process.cwd(), 'messages', `${locale}.json`);
  return JSON.parse(fs.readFileSync(file, 'utf8')) as Record<string, unknown>;
}

test('all interface locales match the English key and placeholder contract', () => {
  const english = flatten(readMessages('en'));
  const englishKeys = Object.keys(english).sort();

  for (const locale of LOCALES) {
    const current = flatten(readMessages(locale));
    assert.deepEqual(Object.keys(current).sort(), englishKeys, `${locale} message keys differ from en`);

    for (const key of englishKeys) {
      assert.deepEqual(
        placeholders(current[key]),
        placeholders(english[key]),
        `${locale}:${key} placeholders differ from en`,
      );
    }
  }
});
