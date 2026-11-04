import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/formatters/financial_amount_validation.dart';

void main() {
  test(
    'shared book and original validators preserve their separate precision and signs',
    () {
      expect(
        validateNonNegativeFinanceBookAmount(
          '1234567890123456789012345678901234567890.123456789012345678901234567890',
        ),
        isNull,
      );
      expect(
        validateSignedFinanceAmount(
          '-1234567890123456789012345678901234567890.123456789012345678901234',
        ),
        isNull,
      );
      expect(
        validateSignedFinanceAmount('0.0000000000000000000000001'),
        isNotNull,
      );
      expect(
        validateNonNegativeFinanceBookAmount(
          '0.0000000000000000000000000000001',
        ),
        isNotNull,
      );
      expect(validateNonNegativeFinanceBookAmount('-0.01'), isNotNull);
      expect(validateSignedFinanceAmount('-0.01'), isNull);
      expect(validateFinanceAmount('0'), isNotNull);
      expect(validateNonNegativeFinanceBookAmount('1.'), isNotNull);
      expect(
        validateSignedFinanceAmount(
          '10000000000000000000000000000000000000000',
        ),
        isNotNull,
      );
      expect(
        validateSignedFinanceAmount('0.123456789012345678901234000000'),
        isNull,
      );
    },
  );
}
