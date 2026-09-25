import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/material_aggregate_order.dart';

void main() {
  test('25000 source intents are submitted in bounded whole-group windows', () {
    final remaining = {for (var i = 0; i < 500; i++) 'material-$i': 50};
    final sizes = <int>[], seen = <String>{};
    while (remaining.isNotEmpty) {
      final window = materialAggregateRequestWindow(remaining);
      sizes.add(window.length);
      expect(
        window.fold<int>(0, (sum, key) => sum + remaining[key]!),
        lessThanOrEqualTo(10000),
      );
      for (final key in window) {
        expect(seen.add(key), isTrue);
        remaining.remove(key);
      }
    }
    expect(sizes, [200, 200, 100]);
    expect(seen, hasLength(500));
  });
  test('group budget is 500 even when source budget is not exhausted', () {
    final groups = {for (var i = 0; i < 501; i++) 'g-$i': 1};
    expect(materialAggregateRequestWindow(groups), hasLength(500));
    expect(materialAggregateRequestWindow(groups).last, 'g-499');
  });
  test(
    'one 10000-source material is kept whole, 10001 is rejected before writing any group',
    () {
      expect(materialAggregateRequestWindow({'large': 10000, 'next': 1}), [
        'large',
      ]);
      expect(
        () => materialAggregateRequestWindow({'valid': 1, 'oversized': 10001}),
        throwsArgumentError,
      );
    },
  );
  test(
    'window never splits a material to fill the remaining source budget',
    () {
      expect(materialAggregateRequestWindow({'first': 9999, 'second': 2}), [
        'first',
      ]);
      expect(materialAggregateRequestWindow({'first': 9999, 'second': 1}), [
        'first',
        'second',
      ]);
    },
  );
}
