import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

void main() {
  test(
    'large facets yield while preserving complete-result totals and rows',
    () async {
      final json = <String, dynamic>{
        'items': List.generate(100, (index) => {'id': index}),
        'page': 3,
        'size': 100,
        'total': 12345,
        'totalPages': 124,
        'facets': {
          'goods': List.generate(
            3000,
            (index) => {
              'value': '$index',
              'label': '物料$index',
              'count': index + 1,
            },
          ),
        },
        'facetNullCounts': {'goods': 17},
      };
      var responsive = false;
      Timer.run(() => responsive = true);
      final actual = await PagedResult.fromJsonResponsive(
        json,
        (row) => row['id'] as int,
        budget: UiWorkBudget(maxItems: 32),
      );
      final expected = PagedResult.fromJson(json, (row) => row['id'] as int);
      expect(responsive, isTrue);
      expect(actual.items, expected.items);
      expect(actual.total, 12345);
      expect(actual.page, 3);
      expect(actual.size, 100);
      expect(actual.totalPages, 124);
      expect(actual.facetNullCounts, expected.facetNullCounts);
      expect(
        actual.facets['goods']!.map(
          (bucket) => (bucket.value, bucket.label, bucket.count),
        ),
        expected.facets['goods']!.map(
          (bucket) => (bucket.value, bucket.label, bucket.count),
        ),
      );
    },
  );
}
