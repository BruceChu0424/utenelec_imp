import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/report/shared/report_cell.dart';
import 'package:uten_imp/features/report/shared/report_column.dart';

void main() {
  const money = ReportColumn(key: 'amount', label: 'amount', type: 'money');
  test('actual report and print cells prefer authoritative decimal text', () {
    expect(
      formatReportCell(money, {
        'amount': 9007199254740992,
        'amountExact': '9007199254740993.0000007',
      }),
      '9007199254740993.0000007',
    );
    expect(
      formatReportCell(money, {'amount': 0, 'amountExact': '0.0000007'}),
      '0.0000007',
    );
    expect(
      formatReportCell(money, {'amount': -1, 'amountExact': '-0.0000007'}),
      '-0.0000007',
    );
    expect(
      formatReportCell(money, {'amount': null, 'amountExact': null}),
      isNull,
    );
  });
  test('legacy numeric reports keep their existing formatting contract', () {
    expect(formatReportCell(money, {'amount': 12.5}), '12.50');
    expect(
      formatReportCell(
        const ReportColumn(key: 'ratio', label: 'ratio', type: 'number'),
        {'ratio': 0, 'ratioExact': '0.123400'},
      ),
      '0.1234',
    );
  });
}
