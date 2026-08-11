import assert from 'node:assert/strict';
import test from 'node:test';

import { buildPageMetadata, directContentLocales, REVIEWED_SITE_LOCALES } from '../lib/seo';

test('unreviewed interface translations stay available but default to noindex', () => {
  const metadata = buildPageMetadata({
    locale: 'fr',
    path: '/capabilities',
    title: 'Capacités',
    description: 'Présentation localisée',
  });

  assert.deepEqual(REVIEWED_SITE_LOCALES, ['zh', 'en']);
  assert.deepEqual(metadata.robots, { index: false, follow: true });
  assert.equal(metadata.alternates?.canonical, 'https://www.ch-uten.com/en/capabilities');
  assert.deepEqual(Object.keys(metadata.alternates?.languages || {}).sort(), ['en', 'x-default', 'zh']);
});

test('reviewed company languages remain indexable', () => {
  const metadata = buildPageMetadata({ locale: 'en', path: '/resources', title: 'Resources' });
  assert.deepEqual(metadata.robots, { index: true, follow: true });
  assert.equal(metadata.alternates?.canonical, 'https://www.ch-uten.com/en/resources');
});

test('direct content locale detection never promotes fallback content', () => {
  const localized = JSON.stringify({
    zh: { title: '标题', content: '正文' },
    en: { title: 'Title', content: '' },
  });
  const locales = directContentLocales<{ title?: string; content?: string }>(
    localized,
    (content) => Boolean(content.title?.trim() && content.content?.trim()),
  );
  assert.deepEqual(locales, ['zh']);
});
