import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/finance/widgets/finance_asset_ui.dart';

void main() {
  test(
    'asset original amounts accept the same exact actual bounds as Java',
    () {
      expect(
        validateFinanceAmount(
          '1234567890123456789012345.123456789012345678901234',
        ),
        isNull,
      );
      expect(validateFinanceAmount('0.000000000000000000000001'), isNull);
      expect(validateFinanceAmount('0.0000000000000000000000001'), isNotNull);
      expect(
        validateFinanceAmount('10000000000000000000000000000000000000000'),
        isNotNull,
      );
      expect(
        validateFinanceAmount('9999999999999999999999999999999999999999'),
        isNull,
      );
      expect(validateFinanceAmount('0'), isNotNull);
      expect(validateFinanceAmount('-1'), isNotNull);
    },
  );

  test(
    'opening book facts retain thirty places without changing their value',
    () {
      expect(
        validateNonNegativeFinanceBookAmount(
          '0.000000000000000000000000000001',
        ),
        isNull,
      );
      expect(
        validateNonNegativeFinanceBookAmount(
          '0.0000000000000000000000000000001',
        ),
        isNotNull,
      );
      expect(
        validateNonNegativeFinanceBookAmount(
          '100.0000000000000000000000000000000',
        ),
        isNull,
      );
      expect(validateNonNegativeFinanceAmount('0'), isNull);
      expect(validateNonNegativeFinanceBookAmount('-0.01'), isNotNull);
      expect(validateNonNegativeFinanceBookAmount('1.'), isNotNull);
    },
  );
}
