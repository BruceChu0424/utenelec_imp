import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/utils/currency_display.dart';

void main() {
  test('currency display prefers a readable master name', () {
    expect(financeCurrencyDisplayLabel(name: '人民币', code: '001'), '人民币');
  });

  test('known ISO currency labels use the established Chinese names', () {
    expect(financeCurrencyDisplayLabel(code: ' USD '), '美金');
    expect(financeCurrencyDisplayLabel(code: 'CNY'), '人民币');
    expect(financeCurrencyDisplayLabel(name: 'RMB'), '人民币');
    expect(financeCurrencyDisplayLabel(name: 'US Dollar', code: 'USD'), '美金');
    expect(financeCurrencyDisplayLabel(name: '美元', code: 'USD'), '美元');
    expect(financeCurrencyDisplayLabel(name: '㐀', code: 'USD'), '㐀');
    expect(
      financeCurrencyDisplayLabel(name: 'Swiss Franc', code: 'CHF'),
      '瑞士法郎',
    );
    expect(financeCurrencyDisplayLabel(name: '港币', code: 'USD'), '港币');
    expect(
      financeCurrencyDisplayLabel(name: 'Unmapped currency'),
      'Unmapped currency',
    );
  });

  test('standard English master names stay Chinese with legacy codes', () {
    expect(financeCurrencyDisplayLabel(name: 'US Dollar', code: '002'), '美金');
    expect(financeCurrencyDisplayLabel(name: 'Euro', code: '003'), '欧元');
    expect(financeCurrencyDisplayLabel(code: 'CHF'), '瑞士法郎');
    expect(financeCurrencyDisplayLabel(name: '港币', code: 'USD'), '港币');
    expect(financeCurrencyDisplayLabel(code: '002'), isNull);
  });

  test('currency display never exposes a legacy numeric code', () {
    expect(financeCurrencyDisplayLabel(code: '001'), isNull);
    expect(financeCurrencyDisplayLabel(name: '002'), isNull);
  });
}
