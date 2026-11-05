import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/formatters/quantity_display.dart';

void main() {
  test(
    'quantity displays preserve every digit despite legacy decimal hints',
    () {
      expect(formatQtyWithUnit(0.0001, '个'), '0.0001 个');
      expect(formatQtyWithUnit(1.2345, '米'), '1.2345 米');
      expect(formatQtyWithUnit(1.2345, 'kg', maxDecimals: 2), '1.2345 kg');
      expect(formatQtyWithUnit(null, '个'), isEmpty);
    },
  );
  test(
    'recorded quantities preserve the smallest allowed quantity and upper boundary',
    () {
      expect(formatExactQtyWithUnit('0.0001', 'PCS'), '0.0001 PCS');
      expect(
        formatExactQtyWithUnit('99999999999999.9999', 'kg'),
        '99999999999999.9999 kg',
      );
      expect(formatExactQtyWithUnit('1.2345', null), '1.2345');
      expect(
        formatExactQtyWithUnit(
          '99999999999999.9999',
          'kg',
          groupThousands: true,
        ),
        '99,999,999,999,999.9999 kg',
      );
      expect(formatExactQtyWithUnit('12.0000', ' PCS '), '12 PCS');
      expect(formatExactQtyWithUnit(null, 'PCS'), isEmpty);
      expect(formatExactQtyWithUnit('unknown', 'PCS'), isEmpty);
    },
  );
}
