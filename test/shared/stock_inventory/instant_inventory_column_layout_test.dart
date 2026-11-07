import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/measurement/weight_unit.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_controller.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_models.dart';
import 'package:uten_imp/shared/stock_inventory/instant_inventory_column_layout.dart';
import 'package:uten_imp/shared/stock_inventory/instant_inventory_columns.dart';

const _oldDefaultOrder = <String>[
  'category',
  'name',
  'goodsCode',
  'color',
  'series',
  'stockPlace',
  'owningWarehouse',
  'model',
  'cNumber',
  'spec',
  'remark',
  'qty',
  'weight',
  'pendingQty',
  'pendingStockInQty',
  'moreQty',
];

void main() {
  final contract =
      jsonDecode(
            File(
              'server/src/test/resources/contracts/instant-inventory-column-order.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final expectedOrder = (contract['columns'] as List).cast<String>();
  final costColumns = (contract['costColumns'] as List).cast<String>().toSet();
  final previousStock = (contract['previousStockDefault'] as List)
      .cast<String>();
  final previousPeriod = (contract['previousPeriodDefault'] as List)
      .cast<String>();
  for (final key in instantInventoryTableKeys) {
    final notifier = PlatformTableLayoutNotifier(key);

    test('$key releases only the old default order and keeps preferences', () {
      const seed = PlatformTableLayout(
        order: _oldDefaultOrder,
        hidden: {'remark', 'series'},
        widths: {'name': 280, 'qty': 210},
        added: [PlatformColumnDefinition(id: 'note', scope: '', name: '自定义说明')],
        sortColumn: 'weight',
        sortAscending: false,
      );
      final migrated = notifier.decode(seed.toJson())!;
      expect(migrated.order, isEmpty);
      expect(migrated.hidden, seed.hidden);
      expect(migrated.widths, seed.widths);
      expect(migrated.pinned, isEmpty);
      expect(migrated.added.single.toJson(), seed.added.single.toJson());
      expect(migrated.sortColumn, 'weight');
      expect(migrated.sortAscending, isFalse);
      expect(migrated.layoutVersion, instantInventoryColumnLayoutVersion);
      expect(
        notifier.defaultValue.layoutVersion,
        instantInventoryColumnLayoutVersion,
      );
    });

    test('$key preserves custom, partial, extended and duplicate orders', () {
      final custom = List.of(_oldDefaultOrder)
        ..remove('qty')
        ..insert(0, 'qty');
      for (final order in [
        custom,
        _oldDefaultOrder.sublist(1),
        [..._oldDefaultOrder, 'extra:note'],
        [..._oldDefaultOrder.take(15), 'pendingQty'],
      ]) {
        final migrated = notifier.decode({'order': order})!;
        expect(migrated.order, order, reason: 'Personal order: $order');
        expect(migrated.layoutVersion, instantInventoryColumnLayoutVersion);
      }
    });

    test('$key preserves pinned layouts even when the old order matches', () {
      final migrated = notifier.decode({
        'order': _oldDefaultOrder,
        'pinned': ['name'],
      })!;
      expect(migrated.order, _oldDefaultOrder);
      expect(migrated.pinned, {'name'});
    });

    test('$key honors a deliberate old order after the migration version', () {
      for (final version in [1, instantInventoryColumnLayoutVersion, 3]) {
        final restored = notifier.decode({
          'order': _oldDefaultOrder,
          'layoutVersion': version,
        })!;
        expect(restored.order, _oldDefaultOrder);
        expect(
          restored.layoutVersion,
          version < instantInventoryColumnLayoutVersion
              ? instantInventoryColumnLayoutVersion
              : version,
        );
        expect(
          notifier.decode(notifier.encode(restored))!.order,
          _oldDefaultOrder,
        );
      }
    });

    test(
      '$key upgrades known v1 defaults without resetting other preferences',
      () {
        for (final order in [
          previousStock,
          previousPeriod,
          previousPeriod.where((key) => !costColumns.contains(key)).toList(),
        ]) {
          final seed = PlatformTableLayout(
            order: order,
            layoutVersion: 1,
            hidden: const {'remark'},
            widths: const {'name': 280},
            added: const [
              PlatformColumnDefinition(id: 'note', scope: '', name: '说明'),
            ],
            sortColumn: 'qty',
            sortAscending: false,
          );
          final migrated = notifier.decode(seed.toJson())!;
          expect(migrated.order, isEmpty);
          expect(migrated.hidden, seed.hidden);
          expect(migrated.widths, seed.widths);
          expect(migrated.added.single.toJson(), seed.added.single.toJson());
          expect(migrated.sortColumn, seed.sortColumn);
          expect(migrated.sortAscending, isFalse);
          expect(migrated.layoutVersion, 2);
        }
      },
    );

    test(
      '$key preserves v1 custom, pinned, partial and extended period orders',
      () {
        final custom = List.of(previousPeriod)
          ..remove('qty')
          ..insert(0, 'qty');
        for (final order in [
          custom,
          previousPeriod.sublist(1),
          [...previousPeriod, 'extra:note'],
        ]) {
          expect(
            notifier.decode({'layoutVersion': 1, 'order': order})!.order,
            order,
          );
        }
        expect(
          notifier.decode({
            'layoutVersion': 1,
            'order': previousPeriod,
            'pinned': ['name'],
          })!.order,
          previousPeriod,
        );
        expect(
          notifier.decode({'layoutVersion': 2, 'order': previousPeriod})!.order,
          previousPeriod,
        );
      },
    );
  }

  testWidgets(
    'permission-dependent columns keep the shared business sequence',
    (tester) async {
      for (final allowed in [false, true]) {
        late List<String> keys;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                keys = instantInventoryColumns(
                  context,
                  weightDisplay: WeightDisplay.auto,
                  canViewCost: allowed,
                ).map((c) => c.key).toList();
                return const SizedBox.shrink();
              },
            ),
          ),
        );
        expect(
          keys,
          expectedOrder
              .where((key) => allowed || !costColumns.contains(key))
              .toList(),
        );
      }
    },
  );

  test('other tables retain the same order and layout version', () {
    final restored = PlatformTableLayoutNotifier(
      'master.supplier',
    ).decode({'order': _oldDefaultOrder})!;
    expect(restored.order, _oldDefaultOrder);
    expect(restored.layoutVersion, 0);
  });

  testWidgets(
    'migrated layouts show inventory facts before master attributes',
    (tester) async {
      late List<String> declaredKeys;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              declaredKeys = instantInventoryColumns(
                context,
                weightDisplay: WeightDisplay.auto,
              ).map((column) => column.key).toList();
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      final controller = PlatformTableController<Object>()
        ..layout = PlatformTableLayoutNotifier(instantInventoryTableKeys.first)
            .decode({
              'order': _oldDefaultOrder,
              'hidden': ['remark'],
              'widths': {'name': 280},
            })!;
      addTearDown(controller.dispose);
      final effective = controller.localLayout(
        declaredKeys,
        defaultHidden: {},
        insertNewColumnsAtDeclaredPosition: true,
      );
      expect(effective.order.take(10), [
        'name',
        'goodsCode',
        'color',
        'qty',
        'reservedQty',
        'availableQty',
        'weight',
        'periodInQty',
        'periodOutQty',
        'closingQty',
      ]);
      expect(effective.order.last, 'remark');
      expect(effective.hidden, {'remark'});
      expect(effective.widths, {'name': 280});

      final personal =
          declaredKeys
              .where((key) => key != 'reservedQty' && key != 'availableQty')
              .toList()
            ..remove('qty')
            ..insert(1, 'qty');
      controller.layout =
          PlatformTableLayoutNotifier(instantInventoryTableKeys.first).decode({
            'layoutVersion': 2,
            'order': personal,
            'hidden': ['remark'],
            'pinned': ['name'],
            'widths': {'qty': 220},
          })!;
      final upgraded = controller.localLayout(
        declaredKeys,
        defaultHidden: {},
        insertNewColumnsAtDeclaredPosition: true,
      );
      expect(upgraded.order.take(4), [
        'name',
        'qty',
        'reservedQty',
        'availableQty',
      ]);
      expect(
        upgraded.order.where(
          (key) => key != 'reservedQty' && key != 'availableQty',
        ),
        personal,
      );
      expect(upgraded.hidden, {'remark'});
      expect(upgraded.pinned, {'name'});
      expect(upgraded.widths, {'qty': 220});
    },
  );
}
