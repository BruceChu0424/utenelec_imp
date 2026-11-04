import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/material_quantity_apportionment.dart';

void main() {
  test(
    'explicit supplier minimum/multiple policy preserves its physical definition',
    () {
      expect(materialQuantityWithOrderPolicy('1.0001', '0', '0.3'), '1.2');
      const q = '9999999999999.9999';
      expect(materialQuantityWithOrderPolicy('1000', q, '0.0001'), q);
      expect(materialQuantityProduct(q, '3'), '29999999999999.9997');
      expect(materialQuantityQuotient('29999999999999.9997', '3'), q);
      expect(materialQuantityQuotient('0.1234', '0.000001'), '123400');
      expect(materialUnitRateFact(null, 0.00032), '0.00032');
      expect(
        materialUnitRateFact('1000000000.000001', null),
        '1000000000.000001',
      );
      expect(
        () => materialUnitRateFact(null, 1000000000.000001),
        throwsFormatException,
      );
      expect(
        () => materialQuantityQuotient('1', '3'),
        throwsA(isA<MaterialQuantityPrecisionRequired>()),
      );
      expect(
        materialQuantityQuotient(
          '1',
          '3',
          precisionScale: 24,
          precisionRounding: 'DOWN',
        ),
        '0.333333333333333333333333',
      );
    },
  );
  test(
    'all supported totals conserve exactly, including 40-place integers and last fractional unit',
    () {
      for (final total in [
        '4500.0001',
        '99999999999999.9999',
        '1234567890123456789012345678901234567890.123456789012345678901234',
        '0.000000000000000000000001',
        '0',
        '3.',
      ]) {
        for (final needs in [
          ['1000', '1000', '1000'],
          ['0', '0', '0'],
          ['1', '0', '1'],
          ['0.1234', '0.1234'],
        ]) {
          final shares = splitTypedTotalText(
            total,
            needs,
            precisionScale: 24,
            precisionRounding: 'DOWN',
          );
          expect(
            shares
                .map(materialQuantityUnits)
                .fold(BigInt.zero, (a, b) => a + b),
            materialQuantityUnits(total),
            reason: '$total / $needs -> $shares',
          );
          expect(
            shares.every((value) => !materialQuantityUnits(value).isNegative),
            isTrue,
          );
        }
      }
    },
  );
  test(
    'finite edits and existing shares never inherit former implicit integer grain',
    () {
      expect(splitTypedTotalText('4500', ['1000', '1000', '1000']), [
        '1500',
        '1500',
        '1500',
      ]);
      expect(splitTypedTotalText('6000', ['1000', '1000', '1000']), [
        '2000',
        '2000',
        '2000',
      ]);
      expect(splitTypedTotalText('3.', ['1', '1']), ['1.5', '1.5']);
      expect(
        coalescedAggregateTotalText(['83.3334', '83.3334', '833.3334']),
        '1000.0002',
      );
      expect(coalescedAggregateShareTexts(['83.3334', '83.3334', '833.3334']), [
        '83.3334',
        '83.3334',
        '833.3334',
      ]);
      expect(coalescedAggregateTotalText(['0.5', '0.5', '0.5']), '1.5');
      expect(coalescedAggregateTotalText(['1', 'missing']), isNull);
      expect(
        () => splitTypedTotalText('0.0000000000000000000000001', ['1']),
        throwsFormatException,
      );
    },
  );
}
