import assert from 'node:assert/strict';
import test from 'node:test';
import { publicNewsWhere, publicProductWhere, publicSeriesWhere } from '../lib/publication';

test('product and series filters compose additional criteria without overriding publication', () => {
  const extra = { slug: 'visible-model', published: false };
  const filter = publicProductWhere(extra);
  assert.deepEqual(filter, { AND: [{ published: true, series: { is: publicSeriesWhere() } }, extra] });
  assert.deepEqual(publicSeriesWhere({ id: 'series' }).AND, [
    { published: true, OR: [
      { catalogRole: 'FAMILY' }, { catalogRole: 'UNCLASSIFIED', parentId: null },
      { catalogRole: { in: ['COLLECTION', 'UNCLASSIFIED'] }, parent: { is: { published: true, catalogRole: 'FAMILY' } } },
      { catalogRole: 'UNCLASSIFIED', parent: { is: { published: true, catalogRole: 'UNCLASSIFIED' } } },
    ] }, { id: 'series' },
  ]);
});

test('public news filter always requires publication', () => {
  assert.deepEqual(publicNewsWhere({ slug: 'published-story' }), { AND: [{ published: true }, { slug: 'published-story' }] });
});
