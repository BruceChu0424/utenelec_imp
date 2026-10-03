import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/finance/models/finance_document_currency.dart';

void main() {
  test('legacy record codes require an explicit currency name', () {
    expect(financeDocumentCurrency(code: '001'), isNull);
    expect(financeDocumentCurrency(code: '002'), isNull);
    expect(financeDocumentCurrency(code: '002', name: '人民币'), 'CNY');
    expect(financeDocumentCurrency(code: '001', name: '美金'), 'USD');
  });
  test('recognized conflicting currency labels fail closed', () {
    expect(financeDocumentCurrency(code: 'USD', name: '人民币'), isNull);
    expect(financeDocumentCurrency(code: 'RMB', name: '美元'), isNull);
  });
  test('only explicit supported currency labels establish equivalence', () {
    expect(financeDocumentCurrency(code: ' cny ', name: '人民币'), 'CNY');
    expect(financeDocumentCurrency(code: '002', name: '日元'), 'JPY');
    expect(financeDocumentCurrency(name: '元'), isNull);
    expect(financeDocumentCurrency(name: '美元/人民币'), isNull);
    expect(financeDocumentCurrency(name: '境外账户'), isNull);
  });
}
