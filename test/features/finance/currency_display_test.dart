import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/utils/currency_display.dart';

void main() {
  test('currency display prefers a readable master name', () {
    expect(financeCurrencyDisplayLabel(name: '人民币', code: '001'), '人民币');
  });

  test('currency display keeps readable ISO codes as a fallback', () {
    expect(financeCurrencyDisplayLabel(code: ' USD '), 'USD');
  });

  test('currency display never exposes a legacy numeric code', () {
    expect(financeCurrencyDisplayLabel(code: '001'), isNull);
    expect(financeCurrencyDisplayLabel(name: '002'), isNull);
  });
}
