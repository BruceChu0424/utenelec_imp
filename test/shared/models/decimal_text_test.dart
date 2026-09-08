import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/models/decimal_text.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';

void main() {
  test(
    'exact editable text survives numeric display loss and preserves zeros',
    () {
      final item = SalesDocItem.fromJson({
        'id': 'line',
        'price': 99999999999999.125,
        'priceExact': '99999999999999.1234',
        'discountExact': '0.8700',
        'qtyExact': '3.0000',
      });
      expect(item.exactDecimals['price'], '99999999999999.1234');
      expect(item.exactDecimals['discount'], '0.8700');
      expect(item.exactDecimals['qty'], '3.0000');
      expect(readExactDecimalTexts({'price': 1, 'priceExact': null}), isEmpty);
    },
  );
  test('preview multiplication never rounds intermediate values', () {
    expect(
      multiplyDecimalTexts(['99999999999999.1234', '3', '0.87']),
      '260999999999997.712074',
    );
    expect(multiplyDecimalTexts(['0.0001', '0.0001']), '0.00000001');
    expect(multiplyDecimalTexts(['-1.25', '2.00']), '-2.5000');
    expect(multiplyDecimalTexts(['NaN', '1']), isNull);
  });
}
