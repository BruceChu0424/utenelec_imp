import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/measurement/document_quantity.dart';

void main() {
  test(
    'material commands retain their independent plain 14/4 write boundary',
    () {
      for (final text in [
        '0.0001',
        '12.7500',
        '1.0000000',
        '99999999999999.9999',
      ]) {
        expect(positiveMaterialCommandQuantityText(text), text);
      }
      for (final text in [
        '',
        '0',
        '-1',
        'NaN',
        '1e3',
        '1.00001',
        '1.0000100',
        '100000000000000',
      ]) {
        expect(positiveMaterialCommandQuantityText(text), isNull, reason: text);
      }
      expect(positiveDocumentQuantityText('1.00001'), '1.00001');
      expect(
        positiveMaterialCommandQuantityText('1e3', plainDecimalOnly: false),
        '1e3',
      );
      for (final text in ['1e-5', '1e14', '1.0000100']) {
        expect(
          positiveMaterialCommandQuantityText(text, plainDecimalOnly: false),
          isNull,
        );
      }
      const fullDocument =
          '9999999999999999999999999999999999999999.999999999999999999999999';
      expect(positiveDocumentQuantityText(fullDocument), fullDocument);
      expect(
        nonNegativeDocumentQuantityText(
          '1.0000000000000000000000000',
          integerDigits: 14,
          fractionDigits: 4,
        ),
        '1',
      );
      expect(
        nonNegativeDocumentQuantityText(
          '0.00001',
          integerDigits: 14,
          fractionDigits: 4,
        ),
        isNull,
      );
    },
  );

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
      expect(positiveDocumentQuantityText('1.00005'), '1.00005');
      expect(positiveDocumentQuantityText('1e4'), '10000');
      expect(
        positiveDocumentQuantityText('0.000000000000000000000001'),
        '0.000000000000000000000001',
      );
    },
  );
  test(
    'invalid document quantities fail without manufacturing a rounded value',
    () {
      for (final input in [
        '1.0000000000000000000000001',
        '10000000000000000000000000000000000000000',
        '0',
        '-1',
        'NaN',
        '',
      ]) {
        expect(positiveDocumentQuantityText(input), isNull, reason: input);
      }
    },
  );
}
