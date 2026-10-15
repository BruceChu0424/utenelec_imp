import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/measurement/exact_measurement_totals.dart';

void main() {
  test(
    'quantities without unit identity stay separate even when labels match',
    () {
      expect(
        exactMeasurementTotalsText(const [
          ExactMeasuredAmount(value: '2', unitId: null, unitName: '个'),
          ExactMeasuredAmount(value: '3', unitId: null, unitName: '个'),
          ExactMeasuredAmount(value: '4', unitId: '', unitName: '千克'),
        ]),
        '2 个 · 3 个 · 4 千克',
      );
    },
  );
  test('unknown quantity without unit identity does not hide other rows', () {
    expect(
      exactMeasurementTotalsText(const [
        ExactMeasuredAmount(value: null, unitId: null, unitName: '个'),
        ExactMeasuredAmount(value: '2', unitId: null, unitName: '个'),
      ]),
      '数量未留存 个 · 2 个',
    );
  });

  test('missing unit names never expose UUIDs or merge distinct units', () {
    expect(
      exactMeasurementTotalsText(const [
        ExactMeasuredAmount(
          value: '2',
          unitId: '00000000-0000-0000-0000-000000000001',
        ),
        ExactMeasuredAmount(
          value: '3',
          unitId: '00000000-0000-0000-0000-000000000002',
        ),
      ]),
      '2 单位未维护 · 3 单位未维护',
    );
  });

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
