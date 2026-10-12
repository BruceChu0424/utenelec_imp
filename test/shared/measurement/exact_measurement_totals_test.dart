import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/measurement/exact_measurement_totals.dart';

void main() {
  test(
    'large four-place quantities sum exactly and distinct unit UUIDs stay separate',
    () {
      expect(
        exactMeasurementTotalsText(const [
          ExactMeasuredAmount(
            value: '9007199254740.1234',
            unitId: 'a',
            unitName: '个',
          ),
          ExactMeasuredAmount(value: '0.0001', unitId: 'a', unitName: '个'),
          ExactMeasuredAmount(value: '2', unitId: 'b', unitName: '个'),
        ]),
        '9007199254740.1235 个 · 2 个',
      );
    },
  );
  test('missing quantity cannot be mistaken for zero', () {
    expect(
      exactMeasurementTotalsText(const [
        ExactMeasuredAmount(value: '3', unitId: 'kg', unitName: '公斤'),
        ExactMeasuredAmount(value: null, unitId: 'kg', unitName: '公斤'),
      ]),
      '数量未留存 公斤',
    );
  });
}
