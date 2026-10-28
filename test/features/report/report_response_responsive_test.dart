import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/features/report/shared/report_data.dart';

void main() {
  test(
    'large report facets yield without changing totals or ready-formatted values',
    () async {
      final json = <String, dynamic>{
        'columns': [
          {'key': 'amount', 'label': '金额', 'type': 'money'},
        ],
        'rows': [
          {'id': 'old-record', 'amount': '98765432109876.1234567890'},
        ],
        'facets': {
          'amount': List.generate(
            3000,
            (index) => {'value': '$index', 'label': '值$index', 'count': index},
          ),
        },
        'page': 2,
        'totalPages': 99,
        'total': 9876,
        'meta': {'currency': 'CNY', 'asOf': 'fixture-watermark'},
        'columnSearchKeys': ['amount'],
      };
      var inputRan = false;
      Timer.run(() => inputRan = true);
      final actual = await parseReportResponseResponsive(json, 1);
      final original = parseReportResponse(json, 1);
      expect(inputRan, isTrue);
      expect(actual.rows, original.rows);
      expect(actual.meta, original.meta);
      expect(actual.columnSearchKeys, {'amount'});
      expect(actual.columnSearchKeys, original.columnSearchKeys);
      expect(actual.total, 9876);
      expect(actual.page, 2);
      expect(actual.totalPages, 99);
      expect(
        actual.facets['amount']!.map(
          (row) => (row.value, row.label, row.count),
        ),
        original.facets['amount']!.map(
          (row) => (row.value, row.label, row.count),
        ),
      );
    },
  );

  test(
    'obsolete report projection stops without publishing a partial result',
    () async {
      var current = true;
      Timer.run(() => current = false);
      await expectLater(
        parseReportResponseResponsive(
          {
            'facets': {
              'goods': List.generate(
                3000,
                (index) => {'value': '$index', 'label': '$index', 'count': 1},
              ),
            },
          },
          1,
          isCurrent: () => current,
        ),
        throwsA(isA<UiWorkCancelled>()),
      );
    },
  );
}
