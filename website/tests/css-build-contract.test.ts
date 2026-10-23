import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import autoprefixer from 'autoprefixer';
import postcss, { type Root, type Rule } from 'postcss';
import nested from 'postcss-nested';
import tailwindcss from 'tailwindcss';
import config from '../tailwind.config';

function rules(root: Root, selector: string) {
  const found: Rule[] = [];
  root.walkRules((rule) => {
    if (rule.selector.includes(selector)) found.push(rule);
  });
  assert.ok(found.length, `Missing generated selector: ${selector}`);
  return found;
}

function values(matches: Rule[], property: string) {
  const found: string[] = [];
  for (const rule of matches) {
    rule.walkDecls(property, (declaration) => { found.push(declaration.value); });
  }
  return found;
}

test('Tailwind 3 keeps Uten tokens, responsive variants and arbitrary child selectors with the patched parser', async () => {
  const source = await readFile('app/globals.css', 'utf8');
  const result = await postcss([
    tailwindcss({
      ...config,
      content: [{
        raw: 'container-uten bg-background md:grid-cols-2 hover:bg-accent dark:text-foreground [&>a]:text-accent',
        extension: 'html',
      }],
    }),
    autoprefixer,
  ]).process(source, { from: 'app/globals.css' });

  assert.deepEqual(result.warnings(), []);
  assert.ok(!result.css.includes('@apply'));
  assert.ok(values(rules(result.root, '.container-uten'), 'max-width').includes('1320px'));
  assert.deepEqual(values(rules(result.root, '.bg-background'), 'background-color'), ['hsl(var(--background))']);
  assert.deepEqual(values(rules(result.root, '.hover\\:bg-accent:hover'), 'background-color'), ['hsl(var(--accent))']);
  assert.deepEqual(values(rules(result.root, '.dark\\:text-foreground'), 'color'), ['hsl(var(--foreground))']);
  const responsive = rules(result.root, '.md\\:grid-cols-2');
  assert.deepEqual(values(responsive, 'grid-template-columns'), ['repeat(2, minmax(0, 1fr))']);
  assert.equal(responsive[0].parent?.type, 'atrule');
  assert.match(responsive[0].parent?.toString() ?? '', /@media \(min-width: 768px\)/);
  const child = rules(result.root, '.\\[\\&\\>a\\]\\:text-accent');
  assert.ok(child.some((rule) => />\s*a$/.test(rule.selector)));
  assert.deepEqual(values(child, 'color'), ['hsl(var(--accent))']);
});

test('postcss-nested retains every parent/state combination and quoted attribute when selector iteration changes', async () => {
  const result = await postcss([nested]).process(`
    .catalog-card, .catalog-tile {
      &:hover, &:focus-visible {
        & > a[data-source="spec,sheet"] { color: teal; }
      }
    }
  `, { from: undefined });
  const actual: string[] = [];
  result.root.walkRules((rule) => { actual.push(...rule.selectors); });
  assert.deepEqual(actual.sort(), [
    '.catalog-card:hover > a[data-source="spec,sheet"]',
    '.catalog-card:focus-visible > a[data-source="spec,sheet"]',
    '.catalog-tile:hover > a[data-source="spec,sheet"]',
    '.catalog-tile:focus-visible > a[data-source="spec,sheet"]',
  ].sort());
  assert.deepEqual(values(rules(result.root, 'data-source'), 'color'), ['teal']);
  assert.deepEqual(result.warnings(), []);
});
