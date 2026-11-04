import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/report/shared/report_cell.dart';
import 'package:uten_imp/features/report/shared/report_column.dart';

void main() {
  test('mixed-currency original money cells retain source currency for table and print', () {
    const amount=ReportColumn(key:'amount',label:'金额',type:'money',unitKey:'currencyCode');
    const exact='12345678901234.123456789012345678901234';
    for(final currency in {'USD':'美金','人民币':'元'}.entries){
      final row=<String,dynamic>{'amount':exact,'currencyCode':currency.key,'__showCurrencyInOriginal':true};
      expect(formatReportCell(amount,row,includeUnit:false),'$exact ${currency.value}');
      expect(row['amount'],exact);
    }
    expect(formatReportCell(amount,{'amount':'100','currencyCode':'USD'},includeUnit:false),'100.00');
    expect(formatReportCell(amount,{'amount':'***','currencyCode':'USD','__showCurrencyInOriginal':true},includeUnit:false),'***');
    const quantity=ReportColumn(key:'qty',label:'数量',type:'number',unitKey:'unit');
    expect(formatReportCell(quantity,{'qty':'3','unit':'只','__showCurrencyInOriginal':true},includeUnit:false),'3');
  });
  test('explicit original-table non-applicable fields stay distinct from missing facts and real zero',(){
    const balance=ReportColumn(key:'balance',label:'结存',type:'number');
    expect(formatReportCell(balance,{'balance':null,'balanceExact':'999','__notApplicable':'price, balance'}),'—');
    expect(formatReportCell(balance,{'balance':null,'balanceExact':'999','__notApplicable':['balance']}),'—');
    expect(formatReportCell(balance,{'balance':null,'balanceExact':'999','__notApplicable':'balanceOther'}),isNull);
    expect(formatReportCell(balance,{'balance':'0','__notApplicable':'price'}),'0');
  });
  const money = ReportColumn(key: 'amount', label: 'amount', type: 'money');
  test(
    'decimal original fields preserve every digit without an Exact alias',
    () {
      const large =
          '1234567890123456789012345678901234567890.123456789012345678901234';
      expect(formatReportCell(money, {'amount': large}), large);
      expect(
        formatReportCell(money, {'amount': '-0.000000000000000000000001'}),
        '-0.000000000000000000000001',
      );
      const qty = ReportColumn(key: 'qty', label: '数量', type: 'number');
      expect(
        formatReportCell(qty, {'qty': '0.000000000000000000000001'}),
        '0.000000000000000000000001',
      );
      expect(
        formatReportCell(qty, {'qty': '-12345678901234567890.123400'}),
        '-12345678901234567890.1234',
      );
      expect(
        formatReportCell(money, {'amount': '***', 'amountExact': large}),
        '***',
      );
      expect(
        formatReportCell(money, {'amount': null, 'amountExact': large}),
        isNull,
      );
      const unit = ReportColumn(
        key: 'amount',
        label: '金额',
        type: 'money',
        unitLabel: '人民币',
      );
      expect(formatReportCell(unit, {'amount': large}), '$large 元');
      expect(
        formatReportCell(unit, {'amount': large}, includeUnit: false),
        large,
      );
    },
  );
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
  test(
    'financial percentage points keep exact scale without multiplying by 100',
    () {
      const rate = ReportColumn(
        key: 'profitRatio',
        label: '月均利润率',
        type: 'number',
        unitLabel: '%',
      );
      expect(
        formatReportCell(rate, {
          'profitRatio': '14.25',
          'profitRatioExact': '14.25',
        }),
        '14.25%',
      );
      expect(
        formatReportCell(rate, {'profitRatio': '9007199254740993.000001'}),
        '9007199254740993.000001%',
      );
      expect(
        formatReportCell(rate, {
          'profitRatio': null,
          'profitRatioExact': '88.8',
        }),
        isNull,
      );
      const month = ReportColumn(key: 'm1', label: '1月', type: 'money');
      expect(
        formatReportCell(month, {
          'm1': '12.5',
          '__percentageKeys': ['m1'],
        }),
        '12.50%',
      );
    },
  );
  test(
    'future month metadata differs from missing source and preserves known zero',
    () {
      const month = ReportColumn(key: 'm10', label: '10月', type: 'money');
      expect(
        formatReportCell(month, {
          'm10': null,
          '__notApplicableMonths': [10, 11, 12],
        }),
        '—',
      );
      expect(formatReportCell(month, {'m10': null}), isNull);
      expect(formatReportCell(month, {'m10': '0', 'm10Exact': '0'}), '0.00');
      const amount = ReportColumn(
        key: 'value',
        label: '金额',
        type: 'money',
        unitLabel: '元',
      );
      expect(
        formatReportCell(amount, {
          'value': '1.23',
          'valueExact': '1.23',
        }, includeUnit: false),
        '1.23',
      );
      const ratio = ReportColumn(
        key: 'value',
        label: '比例',
        type: 'number',
        unitLabel: '%',
      );
      expect(
        formatReportCell(ratio, {'value': '12.5'}, includeUnit: false),
        '12.50%',
      );
    },
  );
}
