import assert from 'node:assert/strict';
import test from 'node:test';
import {
  getDirectNewsContent,
  isNewsCategory,
  parseNewsContent,
} from '../lib/news-content';

test('news categories reject values outside the server allowlist', () => {
  assert.equal(isNewsCategory('company'), true);
  assert.equal(isNewsCategory('industry'), true);
  assert.equal(isNewsCategory('guide'), true);
  assert.equal(isNewsCategory('promotion'), false);
  assert.equal(isNewsCategory('guide<script>'), false);
});

test('direct news lookup never falls back to another locale', () => {
  const i18n = JSON.stringify({
    zh: { title: '中文标题', content: '中文正文' },
    en: { title: 'English title', content: 'English content' },
  });

  assert.equal(getDirectNewsContent(i18n, 'en')?.title, 'English title');
  assert.equal(getDirectNewsContent(i18n, 'de'), null);
});

test('direct news lookup requires both title and body', () => {
  const i18n = JSON.stringify({ en: { title: 'Title only', content: ' ' } });
  assert.equal(getDirectNewsContent(i18n, 'en'), null);
});

test('structured news content groups headings, paragraphs and lists', () => {
  assert.deepEqual(
    parseNewsContent(`## Before approval

Confirm the exact model and market.

- Model and variant
- Document revision

Keep the approval record.`),
    [
      { type: 'heading', text: 'Before approval' },
      { type: 'paragraph', text: 'Confirm the exact model and market.' },
      { type: 'list', items: ['Model and variant', 'Document revision'] },
      { type: 'paragraph', text: 'Keep the approval record.' },
    ],
  );
});

test('article syntax treats HTML-looking input as plain text', () => {
  assert.deepEqual(parseNewsContent('## Safety\n\n<script>alert(1)</script>'), [
    { type: 'heading', text: 'Safety' },
    { type: 'paragraph', text: '<script>alert(1)</script>' },
  ]);
});
