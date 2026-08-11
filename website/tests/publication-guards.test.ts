import assert from 'node:assert/strict';
import test from 'node:test';
import { publicNewsWhere, publicProductWhere } from '../lib/publication';

test('public catalog filter requires an active product, series, and catalog family', () => {
  assert.deepEqual(publicProductWhere({ slug: 'visible-model' }), {
    AND: [
      {
        published: true,
        series: {
          is: {
            published: true,
            OR: [
              { catalogRole: 'FAMILY' },
              { catalogRole: 'UNCLASSIFIED', parentId: null },
              { parent: { is: { published: true, catalogRole: 'FAMILY' } } },
              {
                catalogRole: 'UNCLASSIFIED',
                parent: { is: { published: true, catalogRole: 'UNCLASSIFIED' } },
              },
            ],
          },
        },
      },
      { slug: 'visible-model' },
    ],
  });
});

test('public news filter always requires publication', () => {
  assert.deepEqual(publicNewsWhere({ slug: 'published-story' }), {
    AND: [{ published: true }, { slug: 'published-story' }],
  });
});
