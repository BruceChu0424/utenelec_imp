import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/measurement/measurement_totals.dart';

void main() {
  test('groups strictly by unit id instead of display name', () {
    final totals = groupMeasurementTotals(const [
      MeasuredAmount(value: 2, unitId: 'unit-a', unitName: 'kg'),
      MeasuredAmount(value: 3, unitId: 'unit-a', unitName: '千克'),
      MeasuredAmount(value: 5, unitId: 'unit-b', unitName: 'kg'),
    ]);

    expect(totals, hasLength(2));
    expect(totals[0].unitId, 'unit-a');
    expect(totals[0].value, 5);
    expect(totals[0].rowCount, 2);
    expect(totals[1].unitId, 'unit-b');
    expect(totals[1].value, 5);
  });

  test('keeps missing unit in an explicit independent bucket', () {
    final text = measurementTotalsText(const [
      MeasuredAmount(value: 100, unitId: 'unit-kg', unitName: 'kg'),
      MeasuredAmount(value: 30, unitId: 'unit-piece', unitName: '个'),
      MeasuredAmount(value: 2, unitId: null, unitName: 'kg'),
      MeasuredAmount(value: 1, unitId: '', unitName: '个'),
    ]);

    expect(text, contains('100 kg'));
    expect(text, contains('30 个'));
    expect(text, contains('3 单位未维护'));
    expect(text, isNot(contains('133')));
  });

  test('ignores non-finite values and formats trailing zeroes', () {
    final text = measurementTotalsText([
      const MeasuredAmount(value: 1.2500, unitId: 'unit-m', unitName: '米'),
      const MeasuredAmount(value: double.nan, unitId: 'unit-m', unitName: '米'),
    ]);

    expect(text, '1.25 米');
  });
}
