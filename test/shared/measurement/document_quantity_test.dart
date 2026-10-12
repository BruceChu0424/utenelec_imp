import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/measurement/document_quantity.dart';

void main() {
  test(
    'valid document quantity boundaries survive transport without a double',
    () {
      expect(
        positiveDocumentQuantityText('99999999999999.9999'),
        '99999999999999.9999',
      );
      expect(positiveDocumentQuantityText('10.1256'), '10.1256');
      expect(positiveDocumentQuantityText('0.0001'), '0.0001');
      expect(positiveDocumentQuantityText('12.0000'), '12');
    },
  );
  test(
    'invalid document quantities fail without manufacturing a rounded value',
    () {
      for (final input in [
        '1.00005',
        '100000000000000',
        '0',
        '-1',
        'NaN',
        '1e4',
        '',
      ]) {
        expect(positiveDocumentQuantityText(input), isNull, reason: input);
      }
    },
  );
}
