import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/report/shared/report_cell.dart';
import 'package:uten_imp/features/report/shared/report_column.dart';

Map<String, dynamic> _fixture() =>
    jsonDecode(
          File(
            'contracts/financial-read-facts/statement-original-v1.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

void main() {
  test(
    'Java-generated original wire keeps numeric literals and renders exact aliases across the JSON boundary',
    () {
      final fixture = _fixture();
      final original =
          jsonDecode(fixture['originalRowJson'] as String)
              as Map<String, dynamic>;
      final row =
          jsonDecode(fixture['wireRowJson'] as String) as Map<String, dynamic>;
      final expected = fixture['expectedDisplay'] as Map<String, dynamic>;
      for (final key in original.keys) {
        expect(
          row[key],
          original[key],
          reason: 'Stored literal field $key must remain unchanged',
        );
      }
      const types = {'amount': 'money', 'count': 'count', 'huge': 'count'};
      for (final entry in types.entries) {
        expect(row[entry.key], isA<num>());
        expect(row['${entry.key}Exact'], isA<String>());
        expect(
          formatReportCell(
            ReportColumn(key: entry.key, label: entry.key, type: entry.value),
            row,
          ),
          expected[entry.key],
        );
      }
    },
  );

  test(
    'existing frozen Exact evidence stays authoritative and a masked main value remains masked',
    () {
      final fixture = _fixture();
      final row =
          jsonDecode(fixture['wireRowJson'] as String) as Map<String, dynamic>;
      row['amount'] = 0.1;
      row['amountExact'] = '0.100000000000000000001';
      const amount = ReportColumn(key: 'amount', label: '金额', type: 'money');
      expect(formatReportCell(amount, row), '0.100000000000000000001');
      const masked = ReportColumn(key: 'masked', label: '已屏蔽金额', type: 'money');
      expect(row['maskedExact'], 'original-private-proof');
      expect(formatReportCell(masked, row), isNull);
    },
  );
}
