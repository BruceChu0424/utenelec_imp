import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/material_quantity_apportionment.dart';

void main() {
  test(
    'source shares and total retain the old rounding tail as actual digits',
    () {
      final source = ['83.3334', '83.3334', '833.3334'];
      expect(coalescedAggregateTotalText(source), '1000.0002');
      expect(coalescedAggregateShareTexts(source), source);
      expect(
        materialQuantityFact('0.000000000000000000000001', 0),
        '0.000000000000000000000001',
      );
      expect(
        materialQuantityProduct(
          '0.000000000000000000000001',
          '0.000000000000000000000001',
        ),
        '0.${'0' * 47}1',
      );
    },
  );
  test('finite allocations do not inherit the typed totals decimal grain', () {
    expect(splitTypedTotalText('3', ['1', '1']), ['1.5', '1.5']);
    expect(splitTypedTotalText('6', ['1', '1', '1']), ['2', '2', '2']);
    expect(splitTypedTotalText('10', ['0', '1', '1']), ['0', '5', '5']);
    expect(splitTypedTotalText('0.01', ['10', '10']), ['0.005', '0.005']);
    expect(
      splitTypedTotalText(
        '3',
        ['1', '1'],
        precisionScale: 0,
        precisionRounding: 'HALF_UP',
      ),
      ['1.5', '1.5'],
    );
  });
  test(
    'non-terminating split needs current choice and preserves total with an explicit remainder',
    () {
      expect(
        () => splitTypedTotalText('1', ['0', '0', '0']),
        throwsA(
          isA<MaterialQuantityPrecisionRequired>().having(
            (e) => e.reason,
            'reason',
            'NON_TERMINATING',
          ),
        ),
      );
      final split = splitTypedTotalText(
        '1',
        ['0', '0', '0'],
        precisionScale: 2,
        precisionRounding: 'DOWN',
      );
      expect(split, ['0.33', '0.33', '0.34']);
      expect(
        split
            .map(materialQuantityUnits)
            .fold(BigInt.zero, (sum, value) => sum + value),
        materialQuantityUnits('1'),
      );
      expect(
        () => splitTypedTotalText(
          '0.04',
          List.filled(7, '0'),
          precisionScale: 2,
          precisionRounding: 'HALF_UP',
        ),
        throwsA(
          isA<MaterialQuantityPrecisionRequired>().having(
            (e) => e.exceedsTotal,
            'exceeds',
            true,
          ),
        ),
      );
    },
  );
}
