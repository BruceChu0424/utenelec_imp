import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/formatters/exact_decimal.dart';

void main() {
  test('grouped money preserves exact decimal digits and sign', () {
    expect(
      financeExactMoneyDisplay('99999999999999.1234', groupThousands: true),
      '99,999,999,999,999.1234',
    );
    expect(
      financeExactMoneyDisplay('-1260088.8900', groupThousands: true),
      '-1,260,088.89',
    );
    expect(financeExactMoneyDisplay('0', groupThousands: true), '0.00');
    expect(financeExactMoneyDisplay(null, groupThousands: true), '—');
    expect(
      financeExactMoneyDisplay('99999999999999.1234'),
      '99999999999999.1234',
    );
    expect(financeExactDecimal('1,260.88'), isNull);
  });
}
