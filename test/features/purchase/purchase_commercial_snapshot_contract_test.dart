import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'purchase editor validates and submits the reviewed commercial snapshot',
    () {
      final source = File(
        'lib/features/purchase/pages/purchase_doc_edit_page.dart',
      ).readAsStringSync();

      expect(source, contains("context.appError('请选择币种')"));
      expect(source, contains("context.appError('汇率必须大于 0')"));
      expect(source, contains('parsedTax < 0 || parsedTax > 100'));
      expect(source, contains("'taxRate': taxRate"));
      expect(source, contains("'amountLocal': qty * price * exchangeRate"));
      expect(source, contains("labelText: '税率(%)'"));
      expect(
        source,
        contains("'币种',\n                                      _currencyId"),
      );
    },
  );
}
