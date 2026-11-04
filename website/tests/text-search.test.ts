import assert from 'node:assert/strict';
import test from 'node:test';
import { literalSearchPattern, searchTerms, textSearchRank } from '../lib/text-search';

test('search uses distinct normalized words, literal punctuation and stable exact/prefix ranks', () => {
  assert.deepEqual(searchTerms('  ＡＢ\u3000Panel\tpanel  '), ['ab', 'panel']);
  const terms = searchTerms('Panel AB');
  assert.equal(textSearchRank(['AB-1', 'Panel'], terms), 2);
  assert.equal(textSearchRank(['Panel AB'], terms), 0);
  assert.equal(textSearchRank(['Panel ABC'], terms), 1);
  assert.equal(textSearchRank(['Panel AC'], terms), -1);
  assert.equal(textSearchRank(['A%_\\B'], searchTerms('%_\\')), 2);
  assert.equal(literalSearchPattern('A%_\\B'), 'A\\%\\_\\\\B');
});
