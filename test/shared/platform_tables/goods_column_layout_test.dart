import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/platform_tables/goods_column_layout.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_controller.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_models.dart';

const _releasedDefault = <String>[
  'name',
  'clientGoodsName',
  'nameEn',
  'hasBom',
  'code',
  'colorLegacyId',
  'series',
  'owningWarehouse',
  'owningWorkshop',
  'model',
  'cNumber',
  'spec',
  'paper',
  'mouldCode',
  'mouldName',
  'rearInsertCode',
  'unitLegacyId',
  'material',
  'sourceType',
  'price',
  'discount',
  'stockQty',
  'minOrderQty',
  'orderMultipleQty',
];

void main() {
  final notifier = PlatformTableLayoutNotifier(goodsMasterTableKey);
  for (final price in [false, true]) {
    for (final discount in [false, true]) {
      test(
        'legacy full preset price=$price discount=$discount adopts code first',
        () {
          final order = _releasedDefault
              .where(
                (key) =>
                    (price || key != 'price') &&
                    (discount || key != 'discount'),
              )
              .toList();
          final seed = PlatformTableLayout(
            order: order,
            hidden: const {'paper'},
            widths: const {'name': 280},
            added: const [
              PlatformColumnDefinition(id: 'note', scope: '', name: '自定义'),
            ],
            sortColumn: 'stockQty',
            sortAscending: false,
          );
          final migrated = notifier.decode(seed.toJson())!;
          expect(migrated.order, isEmpty);
          expect(migrated.hidden, seed.hidden);
          expect(migrated.widths, seed.widths);
          expect(migrated.added.single.toJson(), seed.added.single.toJson());
          expect(migrated.sortColumn, 'stockQty');
          expect(migrated.sortAscending, isFalse);
          expect(migrated.layoutVersion, goodsColumnLayoutVersion);
          final controller = PlatformTableController<Object>()
            ..layout = migrated;
          addTearDown(controller.dispose);
          final declared = ['code', ...order.where((key) => key != 'code')];
          expect(
            controller
                .localLayout(
                  declared,
                  defaultHidden: const {},
                  insertNewColumnsAtDeclaredPosition: true,
                )
                .order
                .first,
            'code',
          );
        },
      );
    }
  }
  test('custom, partial, extended and duplicate layouts remain personal', () {
    final reordered = List.of(_releasedDefault)
      ..remove('spec')
      ..insert(0, 'spec');
    for (final order in [
      reordered,
      _releasedDefault.sublist(1),
      [..._releasedDefault, 'platform:custom'],
      [..._releasedDefault.take(23), 'name'],
    ]) {
      expect(notifier.decode({'order': order})!.order, order);
    }
    expect(
      notifier.decode({
        'order': _releasedDefault,
        'pinned': ['name'],
      })!.order,
      _releasedDefault,
    );
  });
  test('explicit old order after version upgrade is never reset again', () {
    for (final version in [goodsColumnLayoutVersion, 2]) {
      final decoded = notifier.decode({
        'order': _releasedDefault,
        'layoutVersion': version,
      })!;
      expect(decoded.order, _releasedDefault);
      expect(notifier.decode(decoded.toJson())!.order, _releasedDefault);
    }
    expect(notifier.defaultValue.layoutVersion, goodsColumnLayoutVersion);
  });
  test('unrelated master tables and picker-sized preferences are retained', () {
    final other = PlatformTableLayoutNotifier(
      'master.supplier',
    ).decode({'order': _releasedDefault})!;
    expect(other.order, _releasedDefault);
    expect(other.layoutVersion, 0);
    expect(
      notifier.decode({
        'order': ['name', 'code', 'series'],
      })!.order,
      ['name', 'code', 'series'],
    );
  });
}
