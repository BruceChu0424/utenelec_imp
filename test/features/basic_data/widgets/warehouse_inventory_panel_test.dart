import 'package:uten_imp/core/utils/date_range_defaults.dart';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/components/data_display/uten_table_output_scope.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/print/uten_print_preview.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/models/warehouse_node.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/warehouse_inventory_panel.dart';
import 'package:uten_imp/shared/stock_inventory/instant_inventory_row.dart';
import 'package:uten_imp/shared/stock_inventory/instant_inventory_repository.dart';
import 'package:uten_imp/shared/stock_inventory/instant_inventory_period_button.dart';
import 'package:uten_imp/components/feedback/uten_date_range_picker.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/paging/complete_paged_snapshot.dart'
    show CompleteReadBatchPlan;
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

/// The (page, size) requests of one complete read under the shared
/// progressive plan: 50 → 50 → 100 → 200 …, each batch at its exact offset.
List<(int, int)> _progressiveBatches(int total) {
  const plan = CompleteReadBatchPlan.progressive;
  final batches = <(int, int)>[];
  var offset = 0;
  do {
    final size = plan.sizeAt(offset);
    batches.add((offset ~/ size + 1, size));
    offset += size;
  } while (offset < total);
  return batches;
}

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
      if (query['dateFrom'] != null && query['dateTo'] != null) ...{
        'periodSelected': true,
        'periodInQty': qty,
        'periodOutQty': 0,
        'closingQty': qty,
        'costMasked': true,
      },
    },
  ],
  'page': query['page'] ?? 1,
  'size': query['size'] ?? 30,
  'total': 1,
  'totalPages': 1,
  'readScopeVersion': 'warehouse-inventory-test-access-v1',
};

Map<String, dynamic> _pagedResult(
  Map<String, dynamic> query, {
  int total = 65,
  String? name,
  num Function(int index)? quantityAt,
}) {
  final result = _result(query, name: name);
  final row = (result['items'] as List).single as Map<String, dynamic>;
  final page = query['page'] as int? ?? 1;
  final size = query['size'] as int? ?? 30;
  final offset = (page - 1) * size;
  return {
    ...result,
    'items': [
      for (var index = offset; index < total && index < offset + size; index++)
        {
          ...row,
          'goodsId': 'goods-${index + 1}',
          'goodsCode': 'M3-${(index + 1).toString().padLeft(3, '0')}',
          if (quantityAt != null) 'qty': quantityAt(index),
          if (index > 0) 'name': '${row['name']} ${index + 1}',
        },
    ],
    'total': total,
    'totalPages': (total / size).ceil(),
  };
}

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
  testWidgets(
    'duplicate identities across complete inventory batches require retry',
    (tester) async {
      final api = _InventoryApi()
        ..respond = (query) async {
          final response = _pagedResult(query);
          if (query['page'] == 2) {
            ((response['items'] as List).first
                    as Map<String, dynamic>)['goodsId'] =
                'goods-1';
          }
          return response;
        };
      await _pump(tester, api: api);
      // The failed read withdraws its provisional first batch as a whole:
      // no row of the duplicate-tainted snapshot stays on screen.
      expect(find.text('hardware库存货品'), findsNothing);
      expect(_table(tester).error, '库存加载失败，请重试');
      expect(_table(tester).isLoading, isFalse);
      expect(find.byType(UtenBusyOverlay), findsNothing);
      api.respond = (query) async => _pagedResult(query);
      _table(tester).onRetry!();
      await tester.pumpAndSettle();
      expect(_table(tester).items, hasLength(65));
      expect(
        _table(tester).items.map((row) => row.rowKey).toSet(),
        hasLength(65),
      );
      expect(_table(tester).error, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('new warehouse inventory uses the recent business month', (
    tester,
  ) async {
    final expected = recentMonthDateRange();
    final harness = await _pump(tester);
    for (final query in harness.api.queries) {
      expect(query['dateFrom'], inventoryPeriodDate(expected.start));
      expect(query['dateTo'], inventoryPeriodDate(expected.end));
    }
    expect(
      tester
          .widget<InstantInventoryPeriodButton>(
            find.byType(InstantInventoryPeriodButton),
          )
          .range,
      expected,
    );
  });

  testWidgets(
    'period clear waits with one overlay and releases it on failure',
    (tester) async {
      final api = _InventoryApi()
        ..respond = (query) async => _pagedResult(query);
      final harness = await _pump(tester, api: api);
      final pending = Completer<Map<String, dynamic>>();
      harness.api.respond = (_) => pending.future;
      final before = harness.api.queries.length;
      final clearPoint = tester.getCenter(
        find.byKey(const Key('instant-inventory-clear-period')),
      );
      await tester.tapAt(clearPoint);
      await tester.pump();
      await tester.pump();
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      for (var repeat = 0; repeat < 12; repeat++) {
        await tester.tapAt(clearPoint);
        await tester.pump();
      }
      expect(harness.api.queries.length, before + 1);
      pending.completeError(StateError('test unavailable'));
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(find.byType(UtenBusyOverlayCard), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'period picker cancels without a query and dates follow print and export',
    (tester) async {
      final harness = await _pump(
        tester,
        permissions: {
          Perm.stockView,
          Perm.stockReportExport,
          Perm.goodsCostView,
        },
      );
      harness.api.respond = (q) =>
          Future.value({..._result(q), 'total': 1, 'totalPages': 1});
      final defaults = recentMonthDateRange();
      expect(
        harness.api.queries.last['dateFrom'],
        inventoryPeriodDate(defaults.start),
      );
      expect(
        harness.api.queries.last['dateTo'],
        inventoryPeriodDate(defaults.end),
      );
      final before = harness.api.queries.length;
      await tester.tap(
        find.byKey(const Key('instant-inventory-select-period')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(UtenDateRangePickerDialog), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(harness.api.queries.length, before);
      final range = DateTimeRange(
        start: DateTime(2026, 10),
        end: DateTime(2026, 10, 31),
      );
      await tester.tap(
        find.byKey(const Key('instant-inventory-select-period')),
      );
      await tester.pumpAndSettle();
      Navigator.of(
        tester.element(find.byType(UtenDateRangePickerDialog)),
      ).pop<UtenDateRangeSelection>((start: range.start, end: range.end));
      await tester.pumpAndSettle();
      expect(harness.api.queries.last['dateFrom'], '2026-10-01');
      expect(harness.api.queries.last['dateTo'], '2026-10-31');
      final export = tester.widget<UtenExportButton>(
        find.byType(UtenExportButton),
      );
      expect(export.queryParams['dateFrom'], '2026-10-01');
      expect(export.queryParams['dateTo'], '2026-10-31');
      // Printing must preserve the same dates across its complete multi-page read.
      final print = tester.widget<UtenPrintPreviewButton>(
        find.byType(UtenPrintPreviewButton),
      );
      await tester.runAsync(() => print.loader());
      expect(
        harness.api.queries
            .skip(before)
            .every(
              (q) =>
                  q['dateFrom'] == '2026-10-01' && q['dateTo'] == '2026-10-31',
            ),
        isTrue,
      );
      await tester.tap(find.byKey(const Key('instant-inventory-clear-period')));
      await tester.pumpAndSettle();
      expect(harness.api.queries.last, isNot(contains('dateFrom')));
      expect(
        _table(tester).columns
            .firstWhere((c) => c.key == 'closingQty')
            .value(_table(tester).items.single),
        '请选择时间范围',
      );
    },
  );

  testWidgets(
    'rapid period changes reject late responses and cost revocation removes sensitive columns',
    (tester) async {
      final api = _InventoryApi();
      final harness = await _pump(
        tester,
        api: api,
        permissions: {Perm.stockView, Perm.goodsCostView},
      );
      final pending = <String, Completer<Map<String, dynamic>>>{};
      api.respond = (query) {
        final date = query['dateFrom'] as String?;
        if (date == null) return Future.value(_result(query));
        return (pending[date] = Completer<Map<String, dynamic>>()).future;
      };
      for (var day = 1; day <= 12; day++) {
        tester
            .widget<InstantInventoryPeriodButton>(
              find.byType(InstantInventoryPeriodButton),
            )
            .onChanged(
              DateTimeRange(
                start: DateTime(2026, 10, day),
                end: DateTime(2026, 10, 31),
              ),
            );
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 100));
      expect(_table(tester).items, isEmpty);
      // Retired reads remain harmless when their responses arrive in reverse order.
      for (final entry in pending.entries.toList().reversed) {
        final result = _result({'dateFrom': entry.key}, name: entry.key);
        ((result['items'] as List).single as Map<String, dynamic>).addAll({
          'periodSelected': true,
          'periodInQty': 12,
          'periodOutQty': 2,
          'closingQty': 10,
          'costPrice': 5,
          'periodCostAmount': 50,
        });
        entry.value.complete(result);
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(_table(tester).items.single.name, '2026-10-12');
      expect(
        _table(tester).columns.map((c) => c.key),
        containsAll(['costPrice', 'periodCostAmount']),
      );
      api.respond = (q) => Future.value(_result(q));
      harness.container.read(_permissions.notifier).replace({Perm.stockView});
      await tester.pumpAndSettle();
      expect(
        _table(tester).columns.map((c) => c.key),
        isNot(anyOf(contains('costPrice'), contains('periodCostAmount'))),
      );
      expect(tester.takeException(), isNull);
    },
  );
  for (final navigation in ['go', 'platform']) {
    testWidgets('$navigation return releases warehouse ledger navigation', (
      tester,
    ) async {
      final api = _InventoryApi()
        ..respond = (query) async => _pagedResult(query);
      final harness = await _pump(tester, api: api);
      for (var visit = 0; visit < 2; visit++) {
        await tester.tap(find.text('hardware库存货品'));
        await tester.pump(const Duration(milliseconds: 60));
        await tester.tap(find.text('hardware库存货品'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('opened-ledger')), findsOneWidget);
        if (navigation == 'go') {
          harness.router.go('/basicinfo/warehouse');
        } else {
          await harness.router.routeInformationProvider.didPushRouteInformation(
            RouteInformation(uri: Uri.parse('/basicinfo/warehouse')),
          );
        }
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('opened-ledger')), findsNothing);
        expect(harness.api.queries.map((query) => query['page']), [
          for (var cycle = 0; cycle < visit + 2; cycle++)
            for (final (page, _) in _progressiveBatches(65)) page,
        ]);
        expect(_table(tester).currentPage, 1);
      }
      expect(tester.takeException(), isNull);
    });
  }

  test('related-only is opt-in and serialized only when requested', () async {
    final api = _InventoryApi();
    final repository = InstantInventoryRepository(api);
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
    final api = _InventoryApi()..respond = (query) async => _pagedResult(query);
    final harness = await _pump(tester, api: api);
    final defaults = recentMonthDateRange();
    expect(harness.api.queries, [
      for (final (page, size) in _progressiveBatches(65))
        {
          'page': page,
          'size': size,
          // Totals and facets come from the first batch only.
          if (page != 1) ...{'includeTotals': false, 'includeFacets': false},
          'warehouseId': 'hardware',
          'includeDefective': true,
          'includeLineSide': true,
          'warehouseRelatedOnly': true,
          'dateFrom': inventoryPeriodDate(defaults.start),
          'dateTo': inventoryPeriodDate(defaults.end),
        },
    ]);
    expect(harness.api.queries.map((query) => query['page']), [1, 2]);
    expect(_table(tester).items, hasLength(65));
    expect(_table(tester).items.first.goodsCode, 'M3-001');
    expect(_table(tester).items.last.goodsId, 'goods-65');
    expect(
      _table(tester).items.map((row) => row.readIdentity).toSet(),
      hasLength(65),
    );
    expect(_table(tester).currentPage, 1);
    expect(_table(tester).embedded, isFalse);
    expect(
      _table(tester).columns
          .singleWhere((column) => column.key == 'qty')
          .value(_table(tester).items.first),
      '0.0001 个',
    );
    // The selected month can show the same exact quantity in multiple columns.
    expect(find.text('0.0001 个'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving during a period read removes the waiting overlay', (
    tester,
  ) async {
    final harness = await _pump(tester);
    final pending = Completer<Map<String, dynamic>>();
    harness.api.respond = (_) => pending.future;
    await tester.tap(find.byKey(const Key('instant-inventory-clear-period')));
    await tester.pump();
    await tester.pump();
    expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(find.byType(UtenBusyOverlayCard), findsNothing);
    pending.complete(_result({'warehouseId': 'hardware'}));
    await tester.pumpAndSettle();
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
      expect(harness.api.queries.map((query) => query['page']), [1]);
      expect(_table(tester).currentPage, 1);
      for (final query in harness.api.queries) {
        expect(query['warehouseId'], warehouse.id);
        expect(query['includeLineSide'], isTrue);
        expect(query['includeDefective'], isTrue);
      }
      expect(_table(tester).items.single.name, '${warehouse.id}库存货品');
      if (warehouse.isMain) {
        const hint = '包含下级核算仓的即时库存';
        expect(find.text(hint), findsNothing);
        await tester.tap(find.byTooltip(hint));
        await tester.pumpAndSettle();
        expect(find.text(hint), findsOneWidget);
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
    final pending = Completer<Map<String, dynamic>>();
    // The final batch of the 65-row read stays in flight.
    final (lastPage, lastSize) = _progressiveBatches(65).last;
    final api = _InventoryApi()
      ..respond = (query) => query['page'] == lastPage
          ? pending.future
          : Future.value(_pagedResult(query));
    final harness = await _pump(tester, api: api, settle: false);
    for (var attempt = 0; attempt < 30 && api.queries.length < 2; attempt++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(harness.api.queries.map((query) => query['page']), [1, 2]);
    await tester.pump();
    // Only the validated first batch is shown provisionally; the in-flight
    // remainder keeps the complete result unaccepted.
    expect(_table(tester).items, hasLength(_progressiveBatches(65).first.$2));
    harness.container.read(_permissions.notifier).replace(const {});
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('warehouse-inventory-no-access')),
      findsOneWidget,
    );
    expect(find.text('hardware库存货品'), findsNothing);
    pending.complete(
      _pagedResult({
        'warehouseId': 'hardware',
        'page': lastPage,
        'size': lastSize,
      }, name: '撤权后的旧响应'),
    );
    await tester.pumpAndSettle();
    expect(find.text('撤权后的旧响应'), findsNothing);
    expect(harness.api.queries, hasLength(2));
    harness.api.respond = (query) async => _pagedResult(query);
    harness.container.read(_permissions.notifier).replace(const {
      Perm.stockView,
    });
    await tester.pumpAndSettle();
    expect(harness.api.queries.map((query) => query['page']), [1, 2, 1, 2]);
    expect(_table(tester).currentPage, 1);
    expect(_table(tester).items, hasLength(65));
    expect(_table(tester).items.first.name, 'hardware库存货品');
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
    final searchQueries = harness.api.queries.where(
      (query) => query['keyword'] == '螺丝',
    );
    expect(searchQueries.map((query) => query['page']), [1]);
    expect(_table(tester).currentPage, 1);
    expect(_table(tester).items.single.name, '搜索后的螺丝');
  });

  testWidgets('complete inventory scrolls without another warehouse request', (
    tester,
  ) async {
    final api = _InventoryApi()..respond = (query) async => _pagedResult(query);
    final harness = await _pump(tester, api: api);
    final before = harness.api.queries.length;
    await tester.drag(
      find.byKey(const Key('warehouse-inventory-table')),
      const Offset(0, -4000),
    );
    await tester.pumpAndSettle();
    expect(harness.api.queries.last['page'], 2);
    expect(harness.api.queries.last['warehouseId'], 'hardware');
    expect(harness.api.queries.last['warehouseRelatedOnly'], isTrue);
    expect(harness.api.queries.map((query) => query['page']), [1, 2]);
    expect(harness.api.queries, hasLength(before));
    expect(_table(tester).items, hasLength(65));
    expect(_table(tester).currentPage, 1);
    expect(_table(tester).totalPages, 1);
    expect(
      find.byKey(const Key('warehouse-inventory-page-size')),
      findsNothing,
    );
    expect(find.text('hardware库存货品 65'), findsOneWidget);
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
      expect(
        _table(tester).columns
            .singleWhere((column) => column.key == 'qty')
            .value(_table(tester).items.single),
        '0 个',
      );
      expect(find.text('0 个'), findsWidgets);
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
              'qty': 10000,
              'qtyExact': '10000',
              'reservedQtyExact': '10000',
              'availableQtyExact': '0',
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
        'pendingQty',
        'pendingStockInQty',
        'stockPlace',
        'owningWarehouse',
        'model',
        'spec',
        'cNumber',
        'series',
        'category',
        'remark',
      ]);
      final values = {
        for (final column in table.columns)
          column.key: column.value(table.items.single),
      };
      expect(values['stockPlace'], 'A31-3-1');
      expect(values['owningWarehouse'], '成品仓');
      expect(values['qty'], '10000 个');
      expect(values['reservedQty'], '10000 个');
      expect(values['availableQty'], '0 个');
      expect(values['weight'], '未称');
      expect(values['pendingStockInQty'], '3 个');
      expect(values['periodInQty'], '服务器未提供期间统计');
      expect(values, isNot(contains('moreQty')));
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
    'facets sorting complete reads and export preserve the selected stock scope',
    (tester) async {
      final api = _InventoryApi()
        ..respond = (query) async => {
          ..._pagedResult(
            query,
            total: query['owningWarehouseNull'] == true ? 2 : 65,
          ),
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
      final defaults = recentMonthDateRange();
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
      expect(
        find.byKey(const Key('warehouse-inventory-page-size')),
        findsNothing,
      );
      expect(harness.api.queries.where((query) => query['page'] == 1).last, {
        'page': 1,
        'size': _progressiveBatches(2).single.$2,
        'warehouseId': 'hardware',
        'includeDefective': true,
        'includeLineSide': true,
        'warehouseRelatedOnly': true,
        'colorId': 'red',
        'series': '金属',
        'owningWarehouseNull': true,
        'dateFrom': inventoryPeriodDate(defaults.start),
        'dateTo': inventoryPeriodDate(defaults.end),
        'sort': 'weight',
        'order': 'asc',
      });
      expect(find.text('共 2 项'), findsOneWidget);
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
        'dateFrom': inventoryPeriodDate(defaults.start),
        'dateTo': inventoryPeriodDate(defaults.end),
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
          ..._pagedResult(query, quantityAt: (index) => index == 64 ? 9935 : 1),
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
      expect(_table(tester).items, hasLength(65));
      expect(harness.api.queries.map((query) => query['page']), [1, 2]);
      final completedRequests = harness.api.queries.length;
      await tester.drag(
        find.byKey(const Key('warehouse-inventory-table')),
        const Offset(0, -4000),
      );
      await tester.pumpAndSettle();
      expect(harness.api.queries, hasLength(completedRequests));
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
    'print reads all 2500 rows in supported batches with identical filters and no cost facts',
    (tester) async {
      const printTotal = 2500;
      // The table read and the print read share one batch ladder, so the
      // fixture switches to the 2500-row print dataset before printing. Every
      // (page, size) request gets its exact slice with one unique identity.
      var servePrintDataset = false;
      final api = _InventoryApi()
        ..respond = (query) async {
          final response = _result(query);
          if (servePrintDataset) {
            final page = query['page'] as int;
            final size = query['size'] as int;
            final offset = (page - 1) * size;
            response['items'] = [
              for (
                var index = offset;
                index < printTotal && index < offset + size;
                index++
              )
                {
                  'goodsId': 'goods-${index + 1}',
                  'name': '打印库存',
                  'colorId': 'red',
                  'qty': 1,
                  'costAmount': 987654.32,
                  'costMasked': true,
                },
            ];
            response['total'] = printTotal;
            response['totalPages'] = (printTotal / size).ceil();
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
      servePrintDataset = true;
      final printStart = harness.api.queries.length;
      // Complete snapshots yield to timer turns between bounded CPU slices.
      final result = (await tester.runAsync(print.loader))!;
      expect(result.rows, hasLength(printTotal));
      final selected = (await tester.runAsync(
        () => selectUtenPrintRows(
          result,
          const UtenTableOutputSelection(
            ids: {'goods-2500|red'},
            rows: [
              {'goodsId': 'goods-2500', 'colorId': 'red'},
            ],
          ),
        ),
      ))!;
      expect(selected.rows, hasLength(1));
      expect(selected.factValues!.single['goodsId'], 'goods-2500');
      expect(selected.factValues!.single['colorId'], 'red');
      expect(result.columnKeys, isNot(contains('costAmount')));
      expect(
        result.factValues!.every((row) => !row.containsKey('costAmount')),
        isTrue,
      );
      final batches = harness.api.queries.skip(printStart).toList();
      expect(
        batches.map((query) => (query['page'], query['size'])),
        _progressiveBatches(printTotal),
      );
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
      final fails = expectLater(
        future,
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'SESSION_CHANGED',
          ),
        ),
      );
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
