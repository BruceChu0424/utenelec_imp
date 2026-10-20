import assert from 'node:assert/strict';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { ESLint } from 'eslint';
import nextVitals from 'eslint-config-next/core-web-vitals';
import configured from '../eslint.config.mjs';

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const eslint = new ESLint({
  cwd: projectRoot,
  overrideConfigFile: true,
  overrideConfig: configured,
});

test('the ESLint 10 adapter preserves all configured Next rules and plugin rules', async () => {
  const original = new ESLint({
    cwd: projectRoot,
    overrideConfigFile: true,
    overrideConfig: [
      ...nextVitals,
      { rules: { 'react-hooks/set-state-in-effect': 'off', 'react-hooks/refs': 'off' } },
    ],
  });
  const fixture = path.join(projectRoot, 'tests/fixtures/eslint-compat.tsx');
  const expected = await original.calculateConfigForFile(fixture);
  const actual = await eslint.calculateConfigForFile(fixture);
  assert.ok(expected);
  assert.ok(actual);
  assert.deepEqual(actual.rules, expected.rules);
  for (const plugin of ['react', 'import', 'jsx-a11y']) {
    assert.deepEqual(
      Object.keys(actual.plugins[plugin].rules).sort(),
      Object.keys(expected.plugins[plugin].rules).sort(),
    );
  }
});

for (const fixture of [
  {
    rule: 'react/jsx-key',
    code: 'export default function Fixture() { return <ul>{[1].map(value => <li>{value}</li>)}</ul>; }',
  },
  {
    rule: 'import/no-anonymous-default-export',
    code: 'export default {};',
  },
  {
    rule: 'jsx-a11y/alt-text',
    code: 'export default function Fixture() { return <img src="/fixture.png" />; }',
  },
]) {
  test(`the adapted original ${fixture.rule} rule still rejects its negative fixture`, async () => {
    const [result] = await eslint.lintText(fixture.code, {
      filePath: path.join(projectRoot, 'tests/fixtures/eslint-compat.tsx'),
    });
    assert.equal(result.fatalErrorCount, 0);
    assert.ok(result.messages.some(message => message.ruleId === fixture.rule && message.severity > 0));
  });
}

test('legacy React and import rules retain the APIs removed by ESLint 10', async () => {
  const legacyRules = new ESLint({
    cwd: projectRoot,
    overrideConfigFile: true,
    overrideConfig: [
      ...configured,
      {
        rules: {
          'react/jsx-curly-spacing': ['error', { when: 'never' }],
          'import/order': ['error', { groups: ['builtin', 'sibling'] }],
        },
      },
    ],
  });
  const [result] = await legacyRules.lintText(
    'import local from "./fixture";\nimport fs from "node:fs";\nexport default function Fixture() { return <div title={ local } />; }',
    { filePath: path.join(projectRoot, 'tests/fixtures/eslint-compat.jsx') },
  );
  assert.equal(result.fatalErrorCount, 0);
  for (const rule of ['react/jsx-curly-spacing', 'import/order']) {
    assert.ok(result.messages.some(message => message.ruleId === rule), `${rule}: ${JSON.stringify(result.messages)}`);
  }
});
