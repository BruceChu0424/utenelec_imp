import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';

void main() {
  for (final type in [
    'receipt',
    'payment',
    'expense',
    'otherIncome',
    'bankTransfer',
  ]) {
    test(
      '$type migrates remark once and retains unrelated layout preferences',
      () {
        final notifier = PlatformTableLayoutNotifier('finance.$type.entry.v1');
        final migrated = notifier.decode({
          'order': [
            'entryAccount',
            'remark',
            'entrySettings',
            'platform:custom',
          ],
          'pinned': ['entryAccount', 'remark'],
          'hidden': ['platform:custom'],
          'widths': {'entryAccount': 240.0, 'remark': 320.0},
        })!;
        expect(migrated.order, [
          'entryAccount',
          'entrySettings',
          'platform:custom',
          'remark',
        ]);
        expect(migrated.pinned, {'entryAccount'});
        expect(migrated.hidden, {'platform:custom'});
        expect(migrated.widths, {'entryAccount': 240.0, 'remark': 320.0});
        expect(migrated.layoutVersion, 1);
        expect(notifier.defaultValue.layoutVersion, 1);
        final userOrder = migrated.copyWith(order: ['remark', 'entryAccount']);
        expect(notifier.decode(userOrder.toJson())!.order, userOrder.order);
      },
    );
  }
  test('unrelated tables do not receive the finance migration', () {
    final layout = PlatformTableLayoutNotifier('master.other').decode({
      'order': ['remark', 'name'],
      'pinned': ['remark'],
    })!;
    expect(layout.order, ['remark', 'name']);
    expect(layout.pinned, {'remark'});
    expect(layout.layoutVersion, 0);
  });
  test('procurement review moves only the old default currency slot', () {
    final notifier = PlatformTableLayoutNotifier(
      'finance.procurement.review.purchase.items',
    );
    final migrated = notifier.decode({
      'order': [
        'price',
        'currency',
        'amountOriginal',
        'exchangeRate',
        'remark',
      ],
      'layoutVersion': 1,
      'pinned': ['price'],
      'hidden': ['remark'],
      'widths': {'currency': 110.0},
    })!;
    expect(migrated.order, [
      'price',
      'amountOriginal',
      'currency',
      'exchangeRate',
      'remark',
    ]);
    expect(migrated.pinned, {'price'});
    expect(migrated.hidden, {'remark'});
    expect(migrated.widths, {'currency': 110.0});
    expect(migrated.layoutVersion, notifier.defaultValue.layoutVersion);

    final customized = migrated.copyWith(
      order: ['currency', 'price', 'amountOriginal'],
      layoutVersion: 1,
    );
    expect(notifier.decode(customized.toJson())!.order, customized.order);
  });
}
