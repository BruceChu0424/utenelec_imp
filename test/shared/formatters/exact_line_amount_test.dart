import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/formatters/exact_decimal.dart';

/// ADR-112: 编辑页金额预览与服务端 MoneyPolicy 同一口径——十进制精确乘积, 不经过 double。
void main() {
  test('3 × 0.1 is exactly 0.3 and × 7.1 is exactly 2.13', () {
    expect(exactLineAmountText('3', '0.1'), '0.3');
    expect(financeExactMultiplyTexts(['3', '0.1', '7.1']), '2.13');
    expect(
      3 * 0.1 == 0.3,
      isFalse,
      reason: 'double 乘法才会得到 0.30000000000000004',
    );
  });

  test(
    'missing or invalid inputs stay unavailable instead of becoming zero',
    () {
      expect(exactLineAmountText('', '1'), isNull);
      expect(exactLineAmountText('2', ' '), isNull);
      expect(exactLineAmountText('2', 'abc'), isNull);
      expect(exactLineAmountText('2', '1', discount: 'x'), isNull);
    },
  );

  test('empty or zero discount means no discount, otherwise it multiplies', () {
    expect(exactLineAmountText('10', '1', discount: ''), '10');
    expect(exactLineAmountText('10', '1', discount: '0'), '10');
    expect(exactLineAmountText('10', '1', discount: '0.0000'), '10');
    expect(exactLineAmountText('10', '1', discount: '0.85'), '8.50');
  });

  test('sum keeps every digit and ignores rows without an amount', () {
    expect(exactAmountSumText(['0.1', '0.2', null]), '0.3');
    expect(exactAmountSumText(const []), '0');
    expect(
      financeExactMoneyDisplay(
        exactAmountSumText(['33.3333', '33.3333', '33.3334']),
      ),
      '100.00',
    );
  });

  test('trimmed display never rounds', () {
    expect(financeExactTrimmed('1.2300'), '1.23');
    expect(financeExactTrimmed('7.123456'), '7.123456');
    expect(
      financeExactTrimmed('123.456789012345678901234'),
      '123.456789012345678901234',
    );
    expect(financeExactTrimmed(null), isNull);
    expect(financeExactMoneyDisplay('0.00000001'), '0.00000001');
  });
}
