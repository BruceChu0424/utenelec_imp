import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/widgets/sales_grid_columns.dart';
import 'package:uten_imp/platform_table_registry.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_binding.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_controller.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_models.dart';
import 'package:uten_imp/shared/providers/editable_grid_column_prefs.dart';
import 'package:uten_imp/shared/sales_review/sales_order_review.dart';
import 'package:uten_imp/shared/widgets/sales_document_layout.dart';

const _legacyOrder = [
  'goods',
  'qty',
  'extra:freight',
  'price',
  'platform:note',
  'amount',
];
const _migratedOrder = [
  'goods',
  'qty',
  'deliveryPlan',
  'extra:freight',
  'price',
  'platform:note',
  'amount',
];

PlatformTableLayout _effectiveOrderLayout<T>() {
  const keys = ['goods', 'qty', 'deliveryPlan', 'price', 'amount'];
  final controller = PlatformTableController<T>()
    ..binding = resolvePlatformTable(
      PlatformTableDescriptor<T>(
        kind: 'master',
        tableKey: salesOrderItemsTableKey,
        columnKeys: keys,
        rows: const [],
      ),
    );
  addTearDown(controller.dispose);
  return controller.localLayout(keys, defaultHidden: {});
}

void main() {
  test('detail and manager finance review retain the delivery entry', () {
    for (final layout in [
      _effectiveOrderLayout<SalesDocItem>(),
      _effectiveOrderLayout<SalesOrderFinanceReviewLine>(),
    ]) {
      expect(layout.hidden, isNot(contains('deliveryPlan')));
      expect(
        layout.order.indexOf('deliveryPlan'),
        layout.order.indexOf('qty') + 1,
      );
    }
  });

  test('finance pending task list keeps its independent display profile', () {
    final binding = resolvePlatformTable(
      const PlatformTableDescriptor<SalesOrderFinancePendingItem>(
        kind: 'master',
        tableKey: salesOrderItemsTableKey,
        columnKeys: ['no', 'clientName', 'status'],
        rows: [],
      ),
    )!;
    expect(binding.scope, 'view_sales_order_finance');
    expect(binding.defaultVisibleColumnKeys, isNull);
    expect(binding.defaultColumnOrder, isNull);
  });

  test('fresh order registry exposes delivery immediately after quantity', () {
    final controller = PlatformTableController<SalesGridRow>()
      ..binding = resolvePlatformTable(
        const PlatformTableDescriptor<SalesGridRow>(
          kind: 'editable',
          tableKey: salesOrderItemsTableKey,
          columnKeys: [
            'goods',
            'qty',
            'deliveryPlan',
            'price',
            'amount',
            'inboundQty',
          ],
          rows: [],
        ),
      );
    addTearDown(controller.dispose);
    final effective = controller.localLayout(
      ['goods', 'qty', 'deliveryPlan', 'price', 'amount', 'inboundQty'],
      defaultHidden: {'inboundQty'},
    );
    expect(effective.hidden, isNot(contains('deliveryPlan')));
    expect(effective.hidden, contains('inboundQty'));
    expect(
      effective.order.indexOf('deliveryPlan'),
      effective.order.indexOf('qty') + 1,
    );
    expect(
      resolvePlatformTable(
        const PlatformTableDescriptor<SalesGridRow>(
          kind: 'editable',
          tableKey: 'sales.quote.items',
          columnKeys: ['goods', 'qty', 'price'],
          rows: [],
        ),
      )!.defaultVisibleColumnKeys,
      isNot(contains('deliveryPlan')),
    );
  });

  for (final accidentallySavedDelivery in [false, true]) {
    final oldOrder = [
      ..._legacyOrder,
      if (accidentallySavedDelivery) 'deliveryPlan',
    ];
    final oldHidden = {
      'platform:note',
      'price',
      if (accidentallySavedDelivery) 'deliveryPlan',
    };

    test(
      'legacy order host repairs delivery only: saved=$accidentallySavedDelivery',
      () {
        final notifier = SalesDocGridColumnPrefsNotifier();
        final decoded = notifier.decode({
          'order': {
            'order': oldOrder,
            'hidden': oldHidden.toList(),
            'pinned': ['goods', 'qty'],
          },
          'quote': {
            'order': oldOrder,
            'hidden': oldHidden.toList(),
            'pinned': ['goods'],
          },
        })!;
        final order = decoded['order']!;
        expect(order.order, _migratedOrder);
        expect(order.hidden, {'platform:note', 'price'});
        expect(order.pinned, {'goods', 'qty'});
        expect(order.layoutVersion, salesOrderColumnLayoutVersion);
        expect(decoded['quote']!.order, oldOrder);
        expect(decoded['quote']!.hidden, oldHidden);
        expect(decoded['quote']!.pinned, {'goods'});
        expect(decoded['quote']!.layoutVersion, 0);
        expect(
          notifier.decode(notifier.encode(decoded))!['order']!.order,
          _migratedOrder,
        );
      },
    );

    test(
      'legacy platform repair preserves extensions widths pins and sort: saved=$accidentallySavedDelivery',
      () {
        final notifier = PlatformTableLayoutNotifier(salesOrderItemsTableKey);
        final seed = PlatformTableLayout(
          order: oldOrder,
          hidden: oldHidden,
          pinned: const {'goods', 'qty'},
          widths: const {'qty': 176, 'platform:note': 312, 'deliveryPlan': 234},
          added: const [
            PlatformColumnDefinition(id: 'note', scope: '', name: '补充说明'),
          ],
          sortColumn: 'amount',
          sortAscending: false,
          hasQueryPreferences: true,
        );
        final restored = notifier.decode(seed.toJson())!;
        expect(restored.order, _migratedOrder);
        expect(restored.hidden, {'platform:note', 'price'});
        expect(restored.pinned, seed.pinned);
        expect(restored.widths, seed.widths);
        expect(restored.added.single.toJson(), seed.added.single.toJson());
        expect(restored.sortColumn, 'amount');
        expect(restored.sortAscending, isFalse);
        expect(restored.hasQueryPreferences, isTrue);
        expect(restored.layoutVersion, salesOrderColumnLayoutVersion);
        expect(
          notifier.decode(notifier.encode(restored))!.toJson(),
          restored.toJson(),
        );
        final quote = PlatformTableLayoutNotifier(
          'sales.quote.items',
        ).decode(seed.toJson())!;
        expect(quote.order, oldOrder);
        expect(quote.hidden, oldHidden);
        expect(quote.layoutVersion, 0);
      },
    );
  }

  test('empty legacy layouts keep the full default rather than one column', () {
    final host = SalesDocGridColumnPrefsNotifier().decode({
      'order': {
        'hidden': ['deliveryPlan', 'price'],
      },
    })!['order']!;
    final platform = PlatformTableLayoutNotifier(salesOrderItemsTableKey)
        .decode({
          'hidden': ['deliveryPlan', 'price'],
        })!;
    expect(host.order, isEmpty);
    expect(platform.order, isEmpty);
    expect(host.hidden, {'price'});
    expect(platform.hidden, {'price'});
    expect(host.layoutVersion, salesOrderColumnLayoutVersion);
    expect(platform.layoutVersion, salesOrderColumnLayoutVersion);
  });

  for (final seed in <List<String>>[
    ['goods', 'price', 'remark'],
    ['goods', 'remark'],
  ]) {
    test('partial legacy schema inserts delivery without reordering $seed', () {
      final restored = PlatformTableLayoutNotifier(
        salesOrderItemsTableKey,
      ).decode({'order': seed})!;
      final expected = [...seed];
      expected.insert(
        seed.contains('price') ? seed.indexOf('price') : seed.length,
        'deliveryPlan',
      );
      expect(restored.order, expected);
      expect(restored.order.where((key) => key != 'deliveryPlan'), seed);
    });
  }

  for (final version in [salesOrderColumnLayoutVersion, 2]) {
    test(
      'subsequent user hiding and order survive reload at version $version',
      () {
        final customOrder = [..._legacyOrder, 'deliveryPlan'];
        const hidden = {'deliveryPlan', 'platform:note'};
        final hostNotifier = SalesDocGridColumnPrefsNotifier();
        final host = hostNotifier.decode({
          'order': {
            'order': customOrder,
            'hidden': hidden.toList(),
            'pinned': ['goods'],
            'layoutVersion': version,
          },
        })!;
        final restoredHost = hostNotifier.decode(
          hostNotifier.encode(host),
        )!['order']!;
        expect(restoredHost.order, customOrder);
        expect(restoredHost.hidden, hidden);
        expect(restoredHost.pinned, {'goods'});
        expect(restoredHost.layoutVersion, version);

        final platformNotifier = PlatformTableLayoutNotifier(
          salesOrderItemsTableKey,
        );
        final platform = platformNotifier.decode({
          'order': customOrder,
          'hidden': hidden.toList(),
          'pinned': ['goods'],
          'layoutVersion': version,
        })!;
        final restoredPlatform = platformNotifier.decode(
          platformNotifier.encode(platform),
        )!;
        expect(restoredPlatform.order, customOrder);
        expect(restoredPlatform.hidden, hidden);
        expect(restoredPlatform.pinned, {'goods'});
        expect(restoredPlatform.layoutVersion, version);
      },
    );
  }

  test('first settings save is versioned so deliberate hiding is retained', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(salesDocGridColumnPrefsProvider.notifier);
    notifier.updateFor(
      'order',
      [..._legacyOrder, 'deliveryPlan'],
      {'deliveryPlan'},
      {'goods'},
    );
    final restored = notifier.decode(
      notifier.encode(container.read(salesDocGridColumnPrefsProvider)),
    )!['order']!;
    expect(restored.hidden, {'deliveryPlan'});
    expect(restored.order.last, 'deliveryPlan');
    expect(restored.layoutVersion, salesOrderColumnLayoutVersion);
    final platform = PlatformTableLayoutNotifier(salesOrderItemsTableKey);
    expect(platform.defaultValue.layoutVersion, salesOrderColumnLayoutVersion);
    final newSettings = platform.defaultValue.copyWith(
      order: _legacyOrder,
      hidden: {'deliveryPlan'},
    );
    expect(platform.decode(platform.encode(newSettings))!.hidden, {
      'deliveryPlan',
    });
  });
}
