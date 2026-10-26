import assert from 'node:assert/strict';
import test from 'node:test';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { PublicationField } from '../components/admin/PublicationField';

test('new content explicitly selects false instead of omitting the publication field', () => {
  const html = renderToStaticMarkup(createElement(PublicationField, { id: 'new-case-publication' }));
  assert.match(html, /<select\b(?=[^>]*name="published")(?=[^>]*id="new-case-publication")[^>]*>/);
  assert.match(html, /<option value="false" selected="">暂不公开，保留内容<\/option>/);
  assert.doesNotMatch(html, /type="checkbox"/);
  assert.match(html, /只有审核发布此版本后/);
});

test('existing publication state and accessible field associations survive server rendering', () => {
  for (const published of [true, false]) {
    const html = renderToStaticMarkup(createElement(PublicationField, { id: 'existing-publication', published }));
    assert.match(html, new RegExp(`<option value="${published ? 'on' : 'false'}" selected="">`));
    assert.match(html, /<label for="existing-publication"/);
    assert.match(html, /aria-describedby="existing-publication-help"/);
    assert.match(html, /id="existing-publication-help"/);
  }
});
