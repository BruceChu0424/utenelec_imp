import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/print/uten_print_preview.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/models/warehouse_node.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/warehouse_inventory_panel.dart';
import 'package:uten_imp/features/stock/models/stock_query.dart';
import 'package:uten_imp/features/stock/repositories/stock_query_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

final _permissions = NotifierProvider<_Permissions, Set<String>>(
  _Permissions.new,
);

class _Permissions extends Notifier<Set<String>> {
  _Permissions([this.initial = const {Perm.stockView}]);

  final Set<String> initial;

  @override
  Set<String> build() => initial;

  void replace(Set<String> permissions) => state = permissions;
}

class _InventoryApi extends ApiClient {
  _InventoryApi() : super(Dio());

  final queries = <Map<String, dynamic>>[];
  Future<Map<String, dynamic>> Function(Map<String, dynamic>)? respond;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != '/stock/instant-inventory') {
      throw StateError('Warehouse inventory must not need master-data reads');
    }
    final copied = Map<String, dynamic>.of(query ?? {});
    queries.add(copied);
    return respond?.call(copied) ?? _result(copied);
  }
}

Map<String, dynamic> _result(
  Map<String, dynamic> query, {
  String? name,
  String? colorId = 'red',
  num qty = 0.0001,
}) => {
  'items': [
    {
      'goodsId': 'goods-1',
      'goodsCode': 'M3-001',
      'name': name ?? '${query['warehouseId']}库存货品',
      'colorId': colorId,
      'colorName': colorId == null ? null : '红色',
      'qty': qty,
      'unitName': '个',
    },
  ],
  'page': query['page'] ?? 1,
  'size': query['size'] ?? 30,
  'total': 65,
  'totalPages': 3,
};

const _warehouse = WarehouseDetail(
  id: 'hardware',
  name: '五金仓',
  parentId: 'main',
);

class _Harness {
  _Harness(this.api, this.container, this.warehouse, this.router);

  final _InventoryApi api;
  final ProviderContainer container;
  final ValueNotifier<WarehouseDetail> warehouse;
  final GoRouter router;
}

Future<_Harness> _pump(
  WidgetTester tester, {
  _InventoryApi? api,
  WarehouseDetail warehouse = _warehouse,
  bool settle = true,
  bool allowed = true,
  Set<String>? permissions,
  Size size = const Size(1100, 750),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final stock = api ?? _InventoryApi();
  final selected = ValueNotifier(warehouse);
  final router = GoRouter(
    initialLocation: '/basicinfo/warehouse',
    routes: [
      GoRoute(
        path: '/basicinfo/warehouse',
        builder: (_, _) => Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(12),
            child: ValueListenableBuilder<WarehouseDetail>(
              valueListenable: selected,
              builder: (_, value, _) =>
                  WarehouseInventoryPanel(warehouse: value),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/stock/item/:id',
        builder: (_, state) => Scaffold(
          body: Text(state.uri.toString(), key: const Key('opened-ledger')),
        ),
      ),
    ],
  );
  addTearDown(() {
    router.dispose();
    selected.dispose();
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(stock),
        authenticatedScopeProvider.overrideWithValue(null),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(_permissions),
        ),
        _permissions.overrideWith(
          () => _Permissions(
            permissions ?? (allowed ? const {Perm.stockView} : const {}),
          ),
        ),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp.router(
        theme: buildLightTheme().copyWith(platform: TargetPlatform.windows),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  await tester.pump();
  if (settle) await tester.pumpAndSettle();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(WarehouseInventoryPanel)),
  );
  return _Harness(stock, container, selected, router);
}

MasterDataTableView<InstantInventoryRow> _table(WidgetTester tester) =>
    tester.widget<MasterDataTableView<InstantInventoryRow>>(
      find.byKey(const Key('warehouse-inventory-table')),
    );

void main() {
  test('related-only is opt-in and serialized only when requested', () async {
    final api = _InventoryApi();
    final repository = StockQueryRepository(api);
    await repository.instantInventory(warehouseId: 'hardware');
    await repository.instantInventory(
      warehouseId: 'hardware',
      warehouseRelatedOnly: true,
    );
    expect(api.queries.first, isNot(contains('warehouseRelatedOnly')));
    expect(api.queries.last['warehouseRelatedOnly'], isTrue);
  });

  testWidgets('reads actual selected stock with precise quantities', (
    tester,
  ) async {
    final harness = await _pump(tester);
    expect(harness.api.queries.single, {
      'page': 1,
      'size': 30,
      'warehouseId': 'hardware',
      'includeDefective': true,
      'includeLineSide': true,
      'warehouseRelatedOnly': true,
    });
    expect(_table(tester).items.single.goodsCode, 'M3-001');
    expect(_table(tester).embedded, isFalse);
    expect(find.text('0.0001 个'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final warehouse in [
    const WarehouseDetail(id: 'main', name: '主仓'),
    const WarehouseDetail(
      id: 'line',
      name: '内料仓',
      parentId: 'main',
      lineSide: true,
      accountable: false,
    ),
    const WarehouseDetail(
      id: 'defective',
      name: '不良品仓',
      parentId: 'main',
      defective: true,
    ),
  ]) {
    testWidgets('${warehouse.id} is queried directly with its actual scope', (
      tester,
    ) async {
      final harness = await _pump(tester, warehouse: warehouse);
      expect(harness.api.queries.single['warehouseId'], warehouse.id);
      expect(harness.api.queries.single['includeLineSide'], isTrue);
      expect(harness.api.queries.single['includeDefective'], isTrue);
      expect(_table(tester).items.single.name, '${warehouse.id}库存货品');
      if (warehouse.isMain) {
        expect(find.text('包含下级核算仓的即时库存'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('switching warehouses rejects the previous late response', (
    tester,
  ) async {
    final pending = Completer<Map<String, dynamic>>();
    final api = _InventoryApi()
      ..respond = (query) => query['warehouseId'] == 'hardware'
          ? pending.future
          : Future.value(_result(query));
    final harness = await _pump(tester, api: api, settle: false);
    harness.warehouse.value = const WarehouseDetail(
      id: 'finished',
      parentId: 'main',
    );
    await tester.pumpAndSettle();
    expect(_table(tester).items.single.name, 'finished库存货品');
    pending.complete(_result({'warehouseId': 'hardware'}, name: '旧仓秘密库存'));
    await tester.pumpAndSettle();
    expect(_table(tester).items.single.name, 'finished库存货品');
    expect(find.text('旧仓秘密库存'), findsNothing);
  });

  testWidgets('missing stock permission never sends an inventory request', (
    tester,
  ) async {
    final harness = await _pump(tester, allowed: false);
    expect(harness.api.queries, isEmpty);
    expect(
      find.byKey(const Key('warehouse-inventory-no-access')),
      findsOneWidget,
    );
  });

  testWidgets('revocation clears old rows and rejects an in-flight response', (
    tester,
  ) async {
    final harness = await _pump(tester);
    final pending = Completer<Map<String, dynamic>>();
    harness.api.respond = (_) => pending.future;
    _table(tester).onPageChange!(2);
    await tester.pump();
    harness.container.read(_permissions.notifier).replace(const {});
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('warehouse-inventory-no-access')),
      findsOneWidget,
    );
    expect(find.text('hardware库存货品'), findsNothing);
    pending.complete(_result({'warehouseId': 'hardware'}, name: '撤权后的旧响应'));
    await tester.pumpAndSettle();
    expect(find.text('撤权后的旧响应'), findsNothing);
    expect(harness.api.queries, hasLength(2));
    harness.api.respond = null;
    harness.container.read(_permissions.notifier).replace(const {
      Perm.stockView,
    });
    await tester.pumpAndSettle();
    expect(harness.api.queries, hasLength(3));
    expect(_table(tester).items.single.name, 'hardware库存货品');
  });

  testWidgets('search invalidates the previous response before debounce ends', (
    tester,
  ) async {
    final pending = Completer<Map<String, dynamic>>();
    final api = _InventoryApi()
      ..respond = (query) => query['keyword'] == null
          ? pending.future
          : Future.value(_result(query, name: '搜索后的螺丝'));
    final harness = await _pump(tester, api: api, settle: false);
    await tester.enterText(find.byType(TextField), '螺丝');
    await tester.pump(const Duration(milliseconds: 100));
    pending.complete(_result({'warehouseId': 'hardware'}, name: '防抖前旧结果'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('防抖前旧结果'), findsNothing);
    await tester.pumpAndSettle();
    expect(harness.api.queries.last['keyword'], '螺丝');
    expect(harness.api.queries.last['page'], 1);
    expect(_table(tester).items.single.name, '搜索后的螺丝');
  });

  testWidgets('pagination keeps warehouse filtering on every request', (
    tester,
  ) async {
    final harness = await _pump(tester);
    _table(tester).onPageChange!(2);
    await tester.pumpAndSettle();
    expect(harness.api.queries.last['page'], 2);
    expect(harness.api.queries.last['warehouseId'], 'hardware');
    expect(harness.api.queries.last['warehouseRelatedOnly'], isTrue);
    expect(_table(tester).currentPage, 2);
    expect(_table(tester).totalPages, 3);
  });

  for (final colorId in ['red', null]) {
    testWidgets('double-click opens warehouse ledger with color $colorId', (
      tester,
    ) async {
      final api = _InventoryApi()
        ..respond = (query) async => _result(query, colorId: colorId);
      await _pump(tester, api: api);
      await tester.tap(find.text('hardware库存货品'));
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.byKey(const Key('opened-ledger')), findsNothing);
      await tester.tap(find.text('hardware库存货品'));
      await tester.pumpAndSettle();
      final uri = Uri.parse(
        tester.widget<Text>(find.byKey(const Key('opened-ledger'))).data!,
      );
      expect(uri.path, '/stock/item/goods-1');
      expect(uri.queryParameters, {
        'tab': 'ledger',
        'warehouseId': 'hardware',
        'includeDefective': 'true',
        'includeLineSide': 'true',
        if (colorId != null) 'colorId': colorId else 'colorNull': 'true',
        'inventoryOnly': 'true',
        'returnTo': '/basicinfo/warehouse',
      });
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'a real zero-balance record is retained and failures are retryable',
    (tester) async {
      var fail = true;
      final api = _InventoryApi()
        ..respond = (query) async {
          if (fail) throw StateError('offline');
          return _result(query, qty: 0);
        };
      await _pump(tester, api: api);
      expect(_table(tester).error, '库存加载失败，请重试');
      fail = false;
      _table(tester).onRetry!();
      await tester.pumpAndSettle();
      expect(_table(tester).items, hasLength(1));
      expect(find.text('0 个'), findsOneWidget);
      expect(_table(tester).error, isNull);
    },
  );

  testWidgets('compact layout stays usable without overflowing', (
    tester,
  ) async {
    await _pump(tester, size: const Size(390, 700));
    expect(find.byKey(const Key('warehouse-inventory-search')), findsOneWidget);
    expect(find.text('0.0001 个'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'inventory uses complete shared columns and keeps unknown weight truthful',
    (tester) async {
      final api = _InventoryApi()
        ..respond = (query) async => {
          ..._result(query),
          'items': [
            {
              'goodsId': 'goods-1',
              'goodsCode': 'M3-001',
              'name': '五金',
              'categoryName': '配件',
              'colorId': 'red',
              'colorName': '红色',
              'model': 'M3',
              'cNumber': 'CLIENT-03',
              'spec': '3 mm',
              'series': '金属件',
              'stockPlace': 'A31-3-1',
              'owningWarehouseId': 'finished',
              'owningWarehouseName': '成品仓',
              'remark': '外购',
              'qty': 10,
              'unitName': '个',
              'weightUnknown': true,
              'pendingQty': 2,
              'pendingStockInQty': 3,
              'moreQty': 4,
              'costMasked': true,
              'costAmount': 987654.32,
            },
          ],
        };
      await _pump(
        tester,
        api: api,
        permissions: {Perm.stockView, Perm.warehouseEdit},
      );
      final table = _table(tester);
      expect(table.showColumnChooser, isTrue);
      expect(table.columnEditingEnabled, isFalse);
      expect(table.columns.map((column) => column.key), [
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
      ]);
      final values = {
        for (final column in table.columns)
          column.key: column.value(table.items.single),
      };
      expect(values['stockPlace'], 'A31-3-1');
      expect(values['owningWarehouse'], '成品仓');
      expect(values['weight'], '未称');
      expect(values['pendingStockInQty'], '3 个');
      expect(values['moreQty'], '4 个');
      expect(
        table.columns.every((column) => !column.supportsKeywordSearch),
        isTrue,
      );
      expect(table.items.single.costAmount, isNull);
      expect(values, isNot(contains('costAmount')));
      expect(find.text('下载表格'), findsNothing);
      expect(find.textContaining('987654'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'facets sorting page size and export all preserve the selected stock scope',
    (tester) async {
      final api = _InventoryApi()
        ..respond = (query) async => {
          ..._result(query),
          'facets': {
            'color': [
              {'value': 'red', 'label': '红色', 'count': 65},
            ],
            'series': [
              {'value': '金属', 'count': 65},
            ],
          },
          'facetNullCounts': {'owningWarehouse': 2},
        };
      final harness = await _pump(
        tester,
        api: api,
        permissions: {Perm.stockView, Perm.stockReportExport},
      );
      expect(_table(tester).facets['color']!.single.label, '红色');
      expect(_table(tester).nullCounts['owningWarehouse'], 2);
      _table(tester).onFilterChanged('color', 'red');
      await tester.pumpAndSettle();
      _table(tester).onFilterChanged('series', '金属');
      await tester.pumpAndSettle();
      _table(tester).onFilterChanged('owningWarehouse', kMasterFilterNullValue);
      await tester.pumpAndSettle();
      _table(tester).onSortChange!('weight', true);
      await tester.pumpAndSettle();
      _table(tester).onPageChange!(2);
      await tester.pumpAndSettle();
      tester
          .widget<UtenDropdownField>(
            find.byKey(const Key('warehouse-inventory-page-size')),
          )
          .onChanged('100');
      await tester.pumpAndSettle();
      expect(harness.api.queries.last, {
        'page': 1,
        'size': 100,
        'warehouseId': 'hardware',
        'includeDefective': true,
        'includeLineSide': true,
        'warehouseRelatedOnly': true,
        'colorId': 'red',
        'series': '金属',
        'owningWarehouseNull': true,
        'sort': 'weight',
        'order': 'asc',
      });
      expect(find.text('共 65 项'), findsOneWidget);
      final export = tester.widget<UtenExportButton>(
        find.byKey(const Key('warehouse-inventory-export')),
      );
      expect(export.requiredPermission, Perm.stockReportExport);
      expect(export.queryParams, {
        'warehouseId': 'hardware',
        'includeDefective': true,
        'includeLineSide': true,
        'warehouseRelatedOnly': true,
        'colorId': 'red',
        'series': '金属',
        'owningWarehouseNull': true,
        'sort': 'weight',
        'order': 'asc',
        'weightUnit': 'KG',
      });
      final selection = await export.prepareExport!();
      expect(selection!.stillCurrent!(), isTrue);
      _table(tester).onSortChange!(null, false);
      await tester.pumpAndSettle();
      expect(harness.api.queries.last, isNot(contains('sort')));
      expect(selection.stillCurrent!(), isFalse);
      final queryCount = harness.api.queries.length;
      _table(tester).onFilterChanged('name', '当前页不得筛选');
      _table(tester).onSortChange!('goodsCode', true);
      await tester.pumpAndSettle();
      expect(harness.api.queries.length, queryCount);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'totals use server full-scope values and hide stale or cost totals',
    (tester) async {
      final pending = Completer<Map<String, dynamic>>();
      final api = _InventoryApi()
        ..respond = (query) async => {
          ..._result(query, qty: 1),
          'totals': [
            {
              'key': 'qty',
              'label': '合计库存数量',
              'type': 'number',
              'groupKey': 'unit_name',
              'groups': [
                {'unit': '个', 'value': 9999},
              ],
            },
            {
              'key': 'pending_qty',
              'label': '合计待检量',
              'type': 'number',
              'groupKey': 'unit_name',
              'groups': [
                {'unit': '个', 'value': 31},
              ],
            },
            {
              'key': 'cost_amount',
              'label': '内部成本',
              'type': 'money',
              'groups': [
                {'value': 987654.32},
              ],
            },
          ],
        };
      final harness = await _pump(tester, api: api);
      expect(find.text('9999 个'), findsOneWidget);
      expect(find.text('31 个'), findsOneWidget);
      expect(find.text('内部成本: '), findsNothing);
      api.respond = (_) => pending.future;
      _table(tester).onFilterChanged('color', 'red');
      await tester.pump();
      expect(find.text('9999 个'), findsNothing);
      expect(find.text('共 65 项'), findsNothing);
      final export = tester.widget<UtenExportButton>(
        find.byKey(const Key('warehouse-inventory-export')),
      );
      expect(export.enabled, isFalse);
      pending.complete(_result(harness.api.queries.last));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'print reads up to 2000 rows in supported batches with identical filters and no cost facts',
    (tester) async {
      final api = _InventoryApi()
        ..respond = (query) async {
          final response = _result(query);
          if (query['size'] == 500) {
            response['items'] = [
              for (var index = 0; index < 500; index++)
                {
                  'goodsId': 'goods-${query['page']}-$index',
                  'name': '打印库存',
                  'colorId': 'red',
                  'qty': 1,
                  'costAmount': 987654.32,
                  'costMasked': true,
                },
            ];
            response['total'] = 2500;
            response['totalPages'] = 5;
          }
          return response;
        };
      final harness = await _pump(tester, api: api);
      _table(tester).onFilterChanged('color', 'red');
      await tester.pumpAndSettle();
      _table(tester).onSortChange!('qty', true);
      await tester.pumpAndSettle();
      final print = tester.widget<UtenPrintPreviewButton>(
        find.byKey(const Key('warehouse-inventory-print')),
      );
      final result = await print.loader();
      expect(result.rows, hasLength(2000));
      expect(result.columnKeys, isNot(contains('costAmount')));
      expect(
        result.factValues!.every((row) => !row.containsKey('costAmount')),
        isTrue,
      );
      final batches = harness.api.queries
          .where((query) => query['size'] == 500)
          .toList();
      expect(batches.map((query) => query['page']), [1, 2, 3, 4]);
      expect(
        batches.every(
          (query) =>
              query['warehouseId'] == 'hardware' &&
              query['warehouseRelatedOnly'] == true &&
              query['colorId'] == 'red' &&
              query['sort'] == 'qty' &&
              query['order'] == 'asc',
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a pending print and prepared export are invalidated when stock permission is revoked',
    (tester) async {
      final harness = await _pump(
        tester,
        permissions: {Perm.stockView, Perm.stockReportExport},
      );
      final pending = Completer<Map<String, dynamic>>();
      harness.api.respond = (_) => pending.future;
      final print = tester.widget<UtenPrintPreviewButton>(
        find.byKey(const Key('warehouse-inventory-print')),
      );
      final export = tester.widget<UtenExportButton>(
        find.byKey(const Key('warehouse-inventory-export')),
      );
      final selection = await export.prepareExport!();
      final future = print.loader();
      final fails = expectLater(future, throwsStateError);
      harness.container.read(_permissions.notifier).replace({
        Perm.stockReportExport,
      });
      await tester.pump();
      pending.complete(_result(harness.api.queries.last));
      await fails;
      await tester.pumpAndSettle();
      expect(selection!.stillCurrent!(), isFalse);
      expect(find.byKey(const Key('warehouse-inventory-table')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
