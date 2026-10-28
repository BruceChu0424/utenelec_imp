import assert from 'node:assert/strict';
import test from 'node:test';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { ClientForm } from '../components/forms/ClientForm';

test('server-rendered client mutation forms keep draft fields out of a GET URL', () => {
  const html = renderToStaticMarkup(createElement(ClientForm, { id: 'editor', onSubmit: () => {} },
    createElement('input', { name: 'message', defaultValue: 'Synthetic private draft' }),
    createElement('button', { type: 'submit' }, 'Save draft')));
  assert.match(html, /<form\b[^>]*method="post"/);
  assert.match(html, /<form\b[^>]*inert=""/);
  assert.match(html, /aria-busy="true"/);
  assert.match(html, /name="message" value="Synthetic private draft"/);
  assert.doesNotMatch(html, /method="get"|action="\?/);
});

test('hydration protection preserves form identity, layout and native field semantics', () => {
  const html = renderToStaticMarkup(createElement(ClientForm, { id: 'resource-editor', className: 'space-y-6', 'aria-label': 'Resource editor' },
    createElement('input', { type: 'hidden', name: 'expectedHash', value: 'synthetic-version' }),
    createElement('fieldset', { disabled: true }, createElement('input', { name: 'title', required: true }))));
  assert.match(html, /id="resource-editor"/);
  assert.match(html, /class="space-y-6"/);
  assert.match(html, /aria-label="Resource editor"/);
  assert.match(html, /type="hidden" name="expectedHash" value="synthetic-version"/);
  assert.match(html, /<fieldset disabled="">/);
  assert.match(html, /<input\b(?=[^>]*\bname="title")(?=[^>]*\brequired="")[^>]*>/);
});
