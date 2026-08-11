import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/utils/idempotency_key.dart';

void main() {
  test('same canonical action reuses the same bounded key', () {
    final first = businessIdempotencyKey(
      'DRAW-ISSUE',
      'doc-1|item-1|issued=0|delta=10',
    );
    final retry = businessIdempotencyKey(
      'DRAW-ISSUE',
      'doc-1|item-1|issued=0|delta=10',
    );

    expect(retry, first);
    expect(first.length, inInclusiveRange(8, 128));
    expect(first, matches(RegExp(r'^DRAW-ISSUE-[0-9a-f]{16}$')));
  });

  test('next partial operation changes when persisted counters change', () {
    final first = businessIdempotencyKey(
      'DRAW-ISSUE',
      'doc-1|item-1|issued=0|delta=10',
    );
    final second = businessIdempotencyKey(
      'DRAW-ISSUE',
      'doc-1|item-1|issued=10|delta=10',
    );

    expect(second, isNot(first));
  });

  test('uses one stable cross-runtime vector including Chinese text', () {
    final key = businessIdempotencyKey(
      'MATERIAL-RETURN',
      '任务-01|物料-A|issued=12.5|return=2.5',
    );

    expect(key, 'MATERIAL-RETURN-10fbbb8d7f776208');
  });
}
