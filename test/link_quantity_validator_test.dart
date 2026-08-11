import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/forms/link_quantity_validator.dart';

void main() {
  group('validateLinkQuantity', () {
    test('accepts a positive finite quantity up to the remaining amount', () {
      expect(validateLinkQuantity('0.5', remaining: 2), isNull);
      expect(validateLinkQuantity('2', remaining: 2), isNull);
      expect(validateLinkQuantity(' 1.25 ', remaining: 2), isNull);
    });

    test('rejects invalid, non-finite, zero and negative quantities', () {
      for (final raw in ['', 'abc', 'NaN', 'Infinity', '0', '-1']) {
        expect(
          validateLinkQuantity(raw, remaining: 2),
          '请输入大于 0 的本次数量',
          reason: raw,
        );
      }
    });

    test('rejects a quantity above the server-derived remaining amount', () {
      expect(validateLinkQuantity('2.01', remaining: 2), '本次数量最多为 2');
      expect(validateLinkQuantity('1', remaining: 0), '该明细已无剩余可引入数量');
      expect(
        validateLinkQuantity('0.000000001', remaining: 0.0000000001),
        isNotNull,
      );
    });
  });

  test('formatLinkQuantity removes only unnecessary trailing zeroes', () {
    expect(formatLinkQuantity(2), '2');
    expect(formatLinkQuantity(2.5), '2.5');
    expect(formatLinkQuantity(2.125), '2.125');
  });

  test(
    'LatestLinkRequestGuard rejects superseded and invalidated requests',
    () {
      final guard = LatestLinkRequestGuard();
      final first = guard.begin();
      expect(guard.isCurrent(first), isTrue);

      final second = guard.begin();
      expect(guard.isCurrent(first), isFalse);
      expect(guard.isCurrent(second), isTrue);

      guard.invalidate();
      expect(guard.isCurrent(second), isFalse);
    },
  );
}
