import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';

void main() {
  test('existing report editor layouts gain both adjacent weight columns', () {
    final layout = PlatformTableLayoutNotifier('production.daily.items').decode(
      {
        'order': ['goods', 'qty', 'remark', 'planNo'],
        'widths': {'planNo': 210},
      },
    )!;
    expect(layout.order, [
      'goods',
      'qty',
      'weight',
      'unitWeight',
      'remark',
      'planNo',
    ]);
    expect(layout.widths, {'planNo': 210});
  });

  for (final table in [
    inboundArrivalRegistrationTableKey,
    finishedArrivalRegistrationTableKey,
  ]) {
    test('$table places unit weight next to the measured weight once', () {
      final layout = PlatformTableLayoutNotifier(table);
      final migrated = layout.decode({
        'order': ['code', 'weight', 'place', 'unitWeight', 'remark'],
        'hidden': ['remark'],
        'pinned': ['code', 'weight'],
        'widths': {'place': 200},
      })!;

      expect(migrated.order, [
        'code',
        'weight',
        'unitWeight',
        'place',
        'remark',
      ]);
      expect(migrated.pinned, {'code', 'weight', 'unitWeight'});
      expect(migrated.hidden, {'remark'});
      expect(migrated.widths, {'place': 200});

      final customized = migrated.copyWith(
        order: ['code', 'weight', 'place', 'remark', 'unitWeight'],
        pinned: {'code', 'weight'},
      );
      expect(layout.decode(customized.toJson())!.order, customized.order);
      expect(layout.decode(customized.toJson())!.pinned, customized.pinned);
    });
  }
}
