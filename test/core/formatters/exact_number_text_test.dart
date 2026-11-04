import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/formatters/exact_number_text.dart';
import 'package:uten_imp/core/formatters/china_number_format.dart';
import 'package:uten_imp/shared/formatters/quantity_display.dart';
import 'package:uten_imp/shared/formatters/exact_decimal.dart';

void main() {
  test('finite business values never obey a smaller display precision cap', () {
    expect(formatChinaNumber(100.005), '100.005');
    expect(formatChinaNumber(12.75), '12.75');
    expect(formatChinaNumber(-1.23456789), '-1.23456789');
    expect(
      formatChinaNumber(
        '1234567890123456789012345678901234567890.123456789012345678901234',
      ),
      '1,234,567,890,123,456,789,012,345,678,901,234,567,890.123456789012345678901234',
    );
    expect(formatChinaNumber(12), '12.00');
    expect(formatQty(12.3456789), '12.3456789');
    expect(formatQtyWithUnit(0.0000007, 'KG', maxDecimals: 0), '0.0000007 KG');
    expect(formatQty(-0.004, maxDecimals: 0), '-0.004');
  });
  test(
    'scientific representation expands using decimal characters without a floating roundtrip',
    () {
      expect(exactNumberText('1e-7'), '0.0000001');
      expect(exactNumberText('-123.456E+4'), '-1234560');
      expect(
        exactNumberText('9999999999999999999999999999999999999999e-24'),
        '9999999999999999.999999999999999999999999',
      );
      expect(exactNumberText(-0.0), '0.0');
      expect(exactNumberText('***'), isNull);
      expect(exactNumberText('1.'), isNull);
      expect(exactNumberText(double.infinity), isNull);
      expect(exactNumberText('1e99999999999999999999'), isNull);
      expect(formatChinaNumber('***'), '***');
    },
  );
  test('all feature decimal helpers share the same text parser', () {
    expect(financeExactDecimal('0001.2300e-2'), '0.012300');
    expect(financeExactMultiplyTexts(['1e-7', '0.7']), '0.00000007');
    expect(financeAmountUnits('1e-24'), BigInt.one);
    expect(financeAmountUnits('1e-25'), isNull);
    expect(
      exactNumberDisplay(
        '-12345.678900',
        minimumFractionDigits: 2,
        groupThousands: true,
      ),
      '-12,345.6789',
    );
  });
}
