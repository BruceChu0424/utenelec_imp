import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/report/shared/report_cell.dart';
import 'package:uten_imp/features/report/shared/report_column.dart';
import 'package:uten_imp/features/report/shared/report_total.dart';

void main() {
  test('server unit metadata drives exact report and print amounts', () {
    final original = ReportColumn.fromJson({
      'key': 'original',
      'label': '原币总额',
      'type': 'money',
      'unitKey': 'currencyCode',
    });
    expect(original.unitKey, 'currencyCode');
    expect(
      formatReportCell(original, {
        'original': 0,
        'originalExact': '99999999999999.1234',
        'currencyCode': '美金',
      }),
      '99999999999999.1234 美金',
    );
    expect(
      formatReportCell(original, {'original': 37.28, 'currencyCode': 'USD'}),
      '37.28 美金',
    );
    expect(
      formatReportCell(original, {'original': 37.28, 'currencyCode': 'CNY'}),
      '37.28 元',
    );
    expect(
      formatReportCell(
        const ReportColumn(
          key: 'billed',
          label: '已出货人民币金额',
          type: 'money',
          unitLabel: '元',
        ),
        {'billed': 0, 'billedExact': '0.0000007'},
      ),
      '0.0000007 元',
    );
  });

  test(
    'quantity units preserve the recorded last digit; missing units stay absent',
    () {
      const quantity = ReportColumn(
        key: 'qty',
        label: '数量',
        type: 'number',
        unitKey: 'unitName',
      );
      expect(
        formatReportCell(quantity, {
          'qty': 0,
          'qtyExact': '99999999999999.1234',
          'unitName': '件',
        }),
        '99999999999999.1234 件',
      );
      expect(
        formatReportCell(quantity, {'qty': 0, 'qtyExact': '0.0001'}),
        '0.0001',
      );
      expect(
        formatReportCell(
          const ReportColumn(key: 'amount', label: '金额', type: 'money'),
          {'amount': 12.5},
        ),
        '12.50',
      );
      expect(
        formatReportCell(
          const ReportColumn(
            key: 'amount',
            label: '金额',
            type: 'money',
            unitKey: 'missing',
          ),
          {'amount': 12.5},
        ),
        '12.50',
      );
    },
  );

  test('masked main values cannot leak a retained Exact value or unit', () {
    const amount = ReportColumn(
      key: 'amount',
      label: '金额',
      type: 'money',
      unitLabel: '美金',
    );
    expect(
      formatReportCell(amount, {'amount': null, 'amountExact': '9000.12'}),
      isNull,
    );
    expect(
      formatReportCell(amount, {'amount': '***', 'amountExact': '9000.12'}),
      '***',
    );
    expect(
      formatReportCell(amount, {
        'amount': 1e30,
        'amountExact': '9007199254740993.0000007',
      }),
      '9007199254740993.0000007 美金',
    );
  });

  test(
    'footer fixed units and exact transport values reuse the same amount contract',
    () {
      final total = ReportTotal.fromJson({
        'key': 'billed',
        'label': '已出货人民币合计',
        'type': 'money',
        'unitLabel': '元',
        'groups': [
          {'unit': null, 'value': 0, 'valueExact': '99999999999999.1234'},
        ],
      });
      expect(reportTotalEntry(total).value, '99999999999999.1234 元');
      final hidden = ReportTotal.fromJson({
        'key': 'billed',
        'label': '已出货人民币合计',
        'type': 'money',
        'unitLabel': '元',
        'groups': [
          {'unit': null, 'value': null, 'valueExact': '99999999999999.1234'},
        ],
      });
      expect(reportTotalEntry(hidden).value, '');
    },
  );

  test('response groups are never summed again by display name', () {
    final total = ReportTotal.fromJson({
      'key': 'amount',
      'label': '原币合计',
      'type': 'money',
      'groupKey': 'currencyCode',
      'groups': [
        {'identity': 'currency-a', 'unit': 'USD', 'value': '12.25'},
        {'identity': 'currency-b', 'unit': 'USD', 'value': '20.50'},
      ],
    });
    expect(reportTotalEntry(total).value, '12.25 美金 · 20.50 美金');
    expect(total.groups.map((group) => group.identity), [
      'currency-a',
      'currency-b',
    ]);
  });

  test('count footer uses declared units and preserves exact integer text', () {
    final total = ReportTotal.fromJson({
      'key': 'rows',
      'label': '行数',
      'type': 'count',
      'unitLabel': '项',
      'groups': [
        {'value': 9007199254740992, 'valueExact': '9007199254740993'},
      ],
    });
    expect(reportTotalEntry(total).value, '9007199254740993 项');
  });

  test(
    'unknown grouped currencies never expose a merged or retained Exact total',
    () {
      for (final unknown in [
        {'unit': null, 'value': null, 'valueExact': '99.99'},
        {'unit': '', 'value': 30, 'valueExact': '30'},
        {'unit': '002', 'value': 30, 'valueExact': '30'},
      ]) {
        final total = ReportTotal.fromJson({
          'key': 'amount',
          'label': '原币合计',
          'type': 'money',
          'groupKey': 'currencyCode',
          'groups': [
            {'unit': '美金', 'value': 10, 'valueExact': '10'},
            unknown,
          ],
        });
        expect(reportTotalEntry(total).value, '10.00 美金 · 币种未维护，合计待核验');
      }
      final allUnknown = ReportTotal.fromJson({
        'key': 'qty',
        'label': '数量合计',
        'type': 'number',
        'groupKey': 'unitName',
        'groups': [
          {'unit': null, 'value': null},
        ],
      });
      expect(reportTotalEntry(allUnknown).value, '单位未维护，合计待核验');
    },
  );
}
