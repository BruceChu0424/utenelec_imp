import 'dart:async';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
// 单货品库存面板 (ADR-135 §6.3) 交互契约:
//  1. KPI 条 + 三分段; 余额重量「≈」/「未称」, 调整/核重按权限出现;
//  2. 余额行「查看流水」切到流水并筛到该仓库 + 颜色 (无颜色 = colorNull);
//     「显示重量调整」进入查询; 合计条期初/本期/期末来自服务端汇总;
//  3. 核重 = POST /stock/weight/balances/set (千克, 带当前重量做乐观核对);
//  4. 单重学习: 卡片 (当前单重/可靠度/依据) + 按权限出现的按钮与子分段 + 记录状态
//     (状态、单重、来源单据已清空都按服务端字段显示)。
// 假接口的回包逐字段照服务端 DTO (StockLedgerPage / WeightObservationRow / BalanceWeightView)。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/stock/models/stock_query.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/measurement/weight_prefs.dart';
import 'package:uten_imp/shared/stock_ledger/goods_stock_ledger_panel.dart';
import 'package:uten_imp/shared/stock_ledger/stock_ledger_models.dart';
import 'package:uten_imp/shared/stock_ledger/widgets/goods_production_trace_view.dart';
import 'package:uten_imp/shared/warehouse/warehouse_task_scope.dart';

class _MemoryWeightUnitsPrefs extends WarehouseWeightUnitsPrefsNotifier {
  @override
  WeightUnitsPrefs build() => const WeightUnitsPrefs();

  @override
  void persist() {}
}

class _PanelApi extends ApiClient {
  _PanelApi() : super(Dio());

  Future<Map<String, dynamic>>? contextResponse;
  final heldGets = <String, Future<Map<String, dynamic>>>{};
  String contextName = '螺丝';

  final ledgerQueries = <Map<String, dynamic>>[];
  final balanceQueries = <Map<String, dynamic>>[];
  final weightQueries = <Map<String, dynamic>>[];
  final posts = <(String, Object?)>[];
  int balanceCalls = 0;
  int traceCalls = 0;
  bool emptyBalances = false;

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('warehouses/dict')) {
      return [
        {'id': 'w1', 'name': '五金仓库', 'selectableForNew': true},
      ];
    }
    if (path.contains('colors/dict')) {
      return [
        {'id': 'c1', 'name': '红'},
      ];
    }
    if (path.contains('units/dict')) {
      return [
        {'id': 'u1', 'name': '个'},
      ];
    }
    if (path.contains('goods') && path.contains('lookup')) {
      return [
        {'id': 'g1', 'name': contextName, 'code': 'S-001', 'unitId': 'u1'},
      ];
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final held = heldGets[path];
    if (held != null) return held;
    if (path.endsWith('/production-trace')) {
      traceCalls++;
      return {'items': <Object>[], 'page': 1, 'size': 50, 'total': 0};
    }
    switch (path) {
      case '/stock/goods/g1/inventory-context':
        if (contextResponse != null) return contextResponse!;
        return {
          'items': [
            {
              'goodsId': 'g1',
              'name': contextName,
              'goodsCode': 'S-001',
              'unitName': '个',
              'qty': 5000,
              'weight': 11.55,
              'weightEstimated': true,
              'colorId': 'c1',
              'colorName': '红',
              'moreQty': 0,
            },
            {
              'goodsId': 'g1',
              'name': contextName,
              'goodsCode': 'S-001',
              'unitName': '个',
              'qty': 20,
              'weight': null,
              'moreQty': 0,
            },
          ],
          'page': 1,
          'size': 500,
          'total': 2,
          'totalPages': 1,
          'totals': [
            {
              'key': 'qty',
              'label': '合计库存数量',
              'type': 'number',
              'groupKey': 'unit_name',
              'groups': [
                {'unit': '个', 'value': 5020},
              ],
            },
            {
              'key': 'weight',
              'label': '合计库存重量',
              'type': 'weight',
              'groupKey': null,
              'groups': [
                {'unit': null, 'value': 11.55},
              ],
            },
            {
              'key': 'weight_unknown_rows',
              'label': '重量未知',
              'type': 'count',
              'groupKey': null,
              'groups': [
                {'unit': null, 'value': 1},
              ],
            },
            {
              'key': 'weight_estimated_rows',
              'label': '重量含估算',
              'type': 'count',
              'groupKey': null,
              'groups': [
                {'unit': null, 'value': 1},
              ],
            },
          ],
        };
      case '/stock/insights/goods/g1':
        return {
          'qty': 12500,
          'weightKg': 28.9,
          'weightEstimated': true,
          'unitWeightKg': 0.002312,
          'tier': 'YELLOW',
          'relHalfWidth': 0.018,
          'abc': 'A',
        };
      case '/stock/balances':
        balanceCalls++;
        balanceQueries.add(Map.of(query ?? const {}));
        return {
          'items': emptyBalances
              ? <Object>[]
              : [
                  {
                    'id': 'b1',
                    'warehouseId': 'w1',
                    'goodsId': 'g1',
                    'colorId': 'c1',
                    'qty': 5000,
                    'weight': 11.55,
                    'weightEstimated': true,
                  },
                  {
                    'id': 'b2',
                    'warehouseId': 'w1',
                    'goodsId': 'g1',
                    'qty': 20,
                    'weight': null,
                  },
                ],
          'page': 1,
          'size': 50,
          'total': 2,
          'totalPages': 1,
        };
      case '/stock/goods/g1/ledger':
        ledgerQueries.add(Map.of(query ?? const {}));
        return {
          'items': [
            {
              'rowKind': 'M',
              'id': 'm1',
              'transactionDate': '2026-09-20T00:00:00+08:00',
              'movementType': 3,
              'typeLabel': '销售出库',
              'direction': -1,
              'sourceDocType': 'SALES_SHIPMENT',
              'sourceDocId': 's1',
              'billNo': 'SS-001',
              'counterpartName': '客户甲',
              'warehouseName': '五金仓库',
              'qtySigned': -100,
              'unitName': '个',
              'weightKgSigned': -0.23,
              'weightSource': 'AVERAGE',
              'balanceQtyAfter': 4900,
              'balanceWeightKgAfter': 11.32,
            },
            {
              'rowKind': 'W',
              'id': 'a1',
              'transactionDate': '2026-09-21T09:30:00+08:00',
              'movementType': null,
              'typeLabel': '人工核重',
              'direction': null,
              'warehouseName': '五金仓库',
              'qtySigned': null,
              'unitName': '个',
              'weightKgSigned': 0.5,
              'weightSource': null,
              'adjustmentKind': 'MANUAL',
              'balanceQtyAfter': 4900,
              'balanceWeightKgAfter': 11.82,
              'remark': '整批过磅',
              'amountLocal': null,
              'costMasked': true,
            },
          ],
          'page': 1,
          'size': 50,
          'total': 2,
          'totalPages': 1,
          'summary': {
            'openingQty': 5000,
            'closingQty': 4900,
            'inQty': 0,
            'outQty': 100,
            'openingWeightKg': 11.55,
            'closingWeightKg': 11.82,
            'outWeightKg': 0.23,
          },
          'facets': {
            'movementType': [
              {'value': '3', 'label': '销售出库', 'count': 1},
              {'value': 'W', 'label': '重量调整', 'count': 1},
            ],
            'warehouse': [
              {'value': 'w1', 'label': '五金仓库', 'count': 2},
            ],
            'color': [
              {'value': '__null__', 'label': '无颜色', 'count': 2},
            ],
          },
        };
      case '/stock/weight/goods/g1':
        return {
          'goodsId': 'g1',
          'profile': {
            'exists': true,
            'tolerancePct': 3,
            'learningEnabled': true,
            'regimeMode': 'AUTO',
            'version': 2,
          },
          'resolved': {
            'goodsId': 'g1',
            'basis': 'LEARNED',
            'evidence': 'REFERENCE',
            'unitWeightKg': 0.002312,
            'logMean': -6.0696,
            'lotPrior': 0.0004,
            'tier': 'YELLOW',
            'nInliers': 21,
          },
          'goodsRow': {
            'evidence': 'REFERENCE',
            'unitWeightKg': 0.002312,
            'nObs': 23,
            'nInliers': 21,
            'tier': 'YELLOW',
            'lastObservedAt': '2026-09-26T02:00:00Z',
          },
          'supplierRows': [
            {
              'supplierId': 'sup-1',
              'supplierName': '甲五金',
              'unitWeightKg': 0.0023,
              'diffPct': -0.5,
              'nRef': 3,
              'tier': 'GREEN',
            },
          ],
          'counts': {'total': 4},
        };
      case '/stock/weight/goods/g1/observations':
        weightQueries.add(Map.of(query ?? const {}));
        Map<String, dynamic> obs(String id, Map<String, dynamic> extra) => {
          'id': id,
          'sourceKind': 'SAMPLE',
          'qtyBase': 20,
          'weightKg': 0.0462,
          'unitWeightKg': 0.00231,
          'observedAt': '2026-09-26T02:00:00Z',
          'stage': 'ACTIVE',
          'sourceDocCleared': null,
          'outlier': false,
          'status': 'NORMAL',
          ...extra,
        };
        return {
          'items': [
            obs('o1', {}),
            obs('o2', {
              'sourceKind': 'RECEIPT',
              'sourceDocType': 'PURCHASE_RECEIPT',
              'sourceDocId': 'r1',
              'billNo': 'PR-001',
              'sourceDocCleared': true,
              'excludedReason': 'MANUAL_EXCLUDE',
              'status': 'EXCLUDED',
            }),
            obs('o3', {'stage': 'REVERSED', 'status': 'REVERSED'}),
            obs('o4', {
              'outlier': true,
              'deviationPct': -4.8,
              'status': 'OUTLIER',
            }),
          ],
          'page': 1,
          'size': 20,
          'total': 4,
          'totalPages': 1,
        };
    }
    return const {};
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    posts.add((path, body));
    if (path == '/stock/weight/params') {
      return {
        'items': [
          {
            'goodsId': 'g1',
            'basis': 'LEARNED',
            'tier': 'YELLOW',
            'unitWeightKg': 0.002312,
          },
        ],
      };
    }
    if (path == '/stock/weight/balances/set') {
      return {
        'adjustmentId': 'adj-1',
        'warehouseId': 'w1',
        'goodsId': 'g1',
        'colorId': 'c1',
        'qty': 5000,
        'weightKg': 0.85,
        'weightEstimated': false,
      };
    }
    return const {};
  }
}

Future<_PanelApi> _pump(
  WidgetTester tester, {
  Set<String> permissions = const {Perm.stockView},
  GoodsStockLedgerSegment initialSegment = GoodsStockLedgerSegment.balance,
  bool withNavigation = false,
  _PanelApi? apiOverride,
}) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final api = apiOverride ?? _PanelApi();
  final home = Scaffold(
    body: GoodsStockLedgerPanel(goodsId: 'g1', initialSegment: initialSegment),
  );
  final router = withNavigation
      ? GoRouter(
          routes: [
            GoRoute(path: '/', builder: (_, _) => home),
            GoRoute(
              path: RouteName.stockInstantInventory,
              builder: (_, _) => const Scaffold(body: Text('即时库存盘点目标页')),
            ),
          ],
        )
      : null;
  if (router != null) addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        warehouseWeightUnitsPrefsProvider.overrideWith(
          _MemoryWeightUnitsPrefs.new,
        ),
      ],
      child: router == null
          ? MaterialApp(home: home)
          : MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

void main() {
  for (final (segment, paths) in [
    (
      GoodsStockLedgerSegment.balance,
      ['/stock/balances', '/stock/insights/goods/g1'],
    ),
    (GoodsStockLedgerSegment.ledger, ['/stock/goods/g1/ledger']),
    (
      GoodsStockLedgerSegment.weight,
      ['/stock/weight/goods/g1', '/stock/weight/goods/g1/observations'],
    ),
    (GoodsStockLedgerSegment.trace, ['/stock/goods/g1/production-trace']),
  ]) {
    testWidgets('reload waits for every visible ${segment.key} request', (
      tester,
    ) async {
      final api = await _pump(
        tester,
        initialSegment: segment,
        permissions: const {Perm.stockView, Perm.productionPlanView},
      );
      final held = {
        for (final path in paths) path: Completer<Map<String, dynamic>>(),
      };
      for (final entry in held.entries) {
        api.heldGets[entry.key] = entry.value.future;
      }
      var finished = false;
      final refresh = tester
          .state<GoodsStockLedgerPanelState>(find.byType(GoodsStockLedgerPanel))
          .reload()
          .then((_) => finished = true);
      await tester.pump();
      await tester.pump();
      expect(finished, isFalse);
      for (var index = 0; index < paths.length; index++) {
        final path = paths[index];
        api.heldGets.remove(path);
        held[path]!.complete(await api.get(path));
        await tester.pump();
        await tester.pump();
        if (index < paths.length - 1) expect(finished, isFalse);
      }
      await tester.pumpAndSettle();
      await refresh;
      expect(finished, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('leaving a visible segment releases its old refresh request', (
    tester,
  ) async {
    final api = await _pump(tester);
    final held = Completer<Map<String, dynamic>>();
    api.heldGets['/stock/balances'] = held.future;
    final panel = tester.state<GoodsStockLedgerPanelState>(
      find.byType(GoodsStockLedgerPanel),
    );
    var finished = false;
    final refresh = panel.reload().then((_) => finished = true);
    await tester.pump();
    await tester.pump();
    expect(finished, isFalse);
    panel.selectSegment(GoodsStockLedgerSegment.ledger);
    await tester.pumpAndSettle();
    await refresh;
    expect(finished, isTrue);
    api.heldGets.remove('/stock/balances');
    held.complete(await api.get('/stock/balances'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'warehouse-only trace waits for participation and hides during revocation',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _PanelApi();
      final initial = Completer<MyWarehouseScope>();
      final refreshed = Completer<MyWarehouseScope>();
      var loads = 0;
      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          currentPermissionsProvider.overrideWithValue({
            Perm.stockView,
            Perm.stockDocView,
          }),
          isSuperAdminProvider.overrideWithValue(false),
          warehouseWeightUnitsPrefsProvider.overrideWith(
            _MemoryWeightUnitsPrefs.new,
          ),
          myWarehouseScopeProvider.overrideWith((ref) {
            return loads++ == 0 ? initial.future : refreshed.future;
          }),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: GoodsStockLedgerPanel(
                goodsId: 'g1',
                initialSegment: GoodsStockLedgerSegment.trace,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('用料追溯'), findsNothing);
      expect(find.byType(GoodsProductionTraceView), findsNothing);
      expect(api.traceCalls, 0);
      initial.complete(const MyWarehouseScope(warehouseParticipant: true));
      await tester.pumpAndSettle();
      expect(find.byType(GoodsProductionTraceView), findsOneWidget);
      expect(api.traceCalls, 1);
      var refreshFinished = false;
      final refresh = tester
          .state<GoodsStockLedgerPanelState>(find.byType(GoodsStockLedgerPanel))
          .reload()
          .then((_) => refreshFinished = true);
      await tester.pumpAndSettle();
      expect(refreshFinished, isFalse);
      expect(find.text('用料追溯'), findsNothing);
      expect(find.byType(GoodsProductionTraceView), findsNothing);
      refreshed.complete(MyWarehouseScope.empty);
      await tester.pumpAndSettle();
      await refresh;
      expect(refreshFinished, isTrue);
      expect(find.byType(GoodsProductionTraceView), findsNothing);
      expect(api.traceCalls, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    },
  );

  testWidgets(
    'account and endpoint switch invalidate an old inventory context response',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final oldResponse = Completer<Map<String, dynamic>>();
      final oldApi = _PanelApi()..contextResponse = oldResponse.future;
      final nextApi = _PanelApi()..contextName = '新公司货品';
      final loadedNames = <String?>[];
      const permissions = {Perm.stockView};
      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(oldApi),
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'old'),
          ),
          currentPermissionsProvider.overrideWithValue(permissions),
          isSuperAdminProvider.overrideWithValue(false),
          warehouseWeightUnitsPrefsProvider.overrideWith(
            _MemoryWeightUnitsPrefs.new,
          ),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: GoodsStockLedgerPanel(
                goodsId: 'g1',
                onGoodsLoaded: (goods) => loadedNames.add(goods.name),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      container.updateOverrides([
        apiClientProvider.overrideWithValue(nextApi),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'new'),
        ),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        warehouseWeightUnitsPrefsProvider.overrideWith(
          _MemoryWeightUnitsPrefs.new,
        ),
      ]);
      await tester.pumpAndSettle();
      expect(loadedNames, ['新公司货品']);
      oldResponse.complete({
        'items': [
          {'goodsId': 'g1', 'name': '旧公司货品', 'unitName': '个', 'qty': 99},
        ],
        'page': 1,
        'size': 50,
        'total': 1,
        'totalPages': 1,
      });
      await tester.pumpAndSettle();
      expect(loadedNames, ['新公司货品']);
      expect(find.text('名称：新公司货品'), findsNothing);
      expect(find.text('名称：旧公司货品'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await tester.pump();
    },
  );

  testWidgets('parent rebuild preserves the selected inventory scope', (
    tester,
  ) async {
    await _pump(tester);
    final panel = tester.state<GoodsStockLedgerPanelState>(
      find.byType(GoodsStockLedgerPanel),
    );
    final selected = panel.scope.withDimensions(
      warehouseId: 'w1',
      colorNull: true,
    );
    panel.selectScope(selected);
    await tester.pumpAndSettle();

    // The goods detail host can rebuild for permissions or other master data
    // while its initial scope remains the same. Keep the employee's range.
    await _pump(tester);
    expect(
      tester.state<GoodsStockLedgerPanelState>(
        find.byType(GoodsStockLedgerPanel),
      ),
      same(panel),
    );
    expect(panel.scope, selected);
    expect(tester.takeException(), isNull);
  });

  testWidgets('balance segment shows KPI, estimated and unknown weights, '
      'and actions by permission', (tester) async {
    final api = await _pump(tester);

    expect(find.byKey(const ValueKey('stock-scoped-totals')), findsOneWidget);
    final balanceTable = tester.widget<MasterDataTableView<BalanceRow>>(
      find.byKey(const Key('stock-item-balance-table')),
    );
    expect(balanceTable.summaryBar, isNotNull);
    expect(balanceTable.summaryBarInline, isTrue);
    expect(find.text('名称：螺丝'), findsNothing);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('stock-scoped-totals'))).dy,
      greaterThan(
        tester
            .getBottomLeft(find.byKey(const ValueKey('balance-view-ledger-b2')))
            .dy,
      ),
      reason: 'Scoped totals belong immediately after the last balance row.',
    );
    expect(
      find.textContaining('库存 12,500'),
      findsNothing,
      reason:
          'Global insight stock totals cannot be mixed into the current scope.',
    );
    expect(find.text('单重 2.312 g (可参考 ±1.8%)'), findsOneWidget);
    for (final label in ['库存余额', '出入库流水', '单重学习']) {
      expect(find.text(label), findsWidgets);
    }
    expect(find.text('≈11.55 kg'), findsOneWidget);
    expect(find.text('未称'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('balance-view-ledger-b1')),
      findsOneWidget,
    );
    // 只有 stock:view: 看得到流水, 不能调整/核重。
    expect(find.byKey(const ValueKey('balance-adjust-b1')), findsNothing);
    expect(find.byKey(const ValueKey('balance-weigh-b1')), findsNothing);
    await tester.tap(find.text('库存数量'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从大到小'));
    await tester.pumpAndSettle();
    expect(api.balanceQueries.last['sort'], 'qty');
    expect(api.balanceQueries.last['order'], 'desc');
    expect(api.balanceQueries.last['page'], 1);
    expect(api.balanceQueries.last['goodsId'], 'g1');
    tester
        .widget<MasterDataTableView<BalanceRow>>(
          find.byKey(const Key('stock-item-balance-table')),
        )
        .onFilterChanged('search.qty', '>=5000');
    await tester.pumpAndSettle();
    expect(api.balanceQueries.last['search.qty'], '>=5000');
    expect(api.balanceQueries.last['sort'], 'qty');
  });

  testWidgets(
    'empty stock totals stay below the table and fit a narrow large-text view',
    (tester) async {
      final api = _PanelApi()
        ..emptyBalances = true
        ..contextResponse = Future.value({
          'items': <Object>[],
          'page': 1,
          'size': 50,
          'total': 0,
          'totalPages': 1,
          'totals': [
            for (final key in ['qty', 'pending_qty', 'pending_stock_in_qty'])
              {
                'key': key,
                'label': switch (key) {
                  'qty' => '合计库存数量',
                  'pending_qty' => '合计待检量',
                  _ => '合计合格待入库',
                },
                'type': 'number',
                'groupKey': 'unit_name',
                'groups': [
                  {'unit': '个', 'value': key == 'pending_qty' ? 6 : 0},
                ],
              },
          ],
        });
      await _pump(tester, apiOverride: api);
      tester.view.physicalSize = const Size(390, 844);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();

      final summary = find.byKey(const ValueKey('stock-scoped-totals'));
      await tester.ensureVisible(summary);
      await tester.pumpAndSettle();
      final bounds = tester.getRect(summary);
      expect(bounds.left, greaterThanOrEqualTo(0));
      expect(bounds.right, lessThanOrEqualTo(390));
      expect(
        bounds.top,
        greaterThanOrEqualTo(tester.getBottomLeft(find.text('该货品暂无库存余额')).dy),
      );
      expect(find.text('合计待检量: '), findsOneWidget);
      expect(find.text('6 个'), findsOneWidget);
      expect(find.text('合计合格待入库: '), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'old weight and balance permissions no longer reveal retired direct edits',
    (tester) async {
      await _pump(
        tester,
        permissions: const {
          Perm.stockView,
          Perm.stockBalanceAdjust,
          Perm.stockWeightManage,
        },
      );
      expect(find.byKey(const ValueKey('balance-adjust-b1')), findsNothing);
      expect(find.byKey(const ValueKey('balance-weigh-b1')), findsNothing);
      expect(find.byKey(const ValueKey('balance-count-b1')), findsNothing);
    },
  );

  testWidgets('view ledger filters to the balance dimension and the '
      'adjustments toggle reaches the query', (tester) async {
    final api = await _pump(tester);

    await tester.tap(find.byKey(const ValueKey('balance-view-ledger-b2')));
    await tester.pumpAndSettle();

    final first = api.ledgerQueries.last;
    expect(first['warehouseId'], 'w1');
    expect(first['colorNull'], isTrue, reason: '无颜色的余额行只看无颜色维度');
    expect(first.containsKey('colorId'), isFalse);
    expect(first['dateFrom'], isNotNull);
    expect(first['dateTo'], isNotNull);
    expect(first.containsKey('includeWeightAdjustments'), isFalse);

    expect(find.text('SS-001'), findsOneWidget);
    // 重量调整行的类型名由服务端给。
    expect(find.text('人工核重'), findsOneWidget);
    expect(find.text('≈230 g'), findsOneWidget, reason: '按库存均重估算的发出重量带「≈」');
    expect(find.textContaining('期初结存'), findsOneWidget);
    expect(find.text('5,000 个 · 11.55 kg'), findsOneWidget);
    expect(find.text('4,900 个 · 11.82 kg'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('stock-ledger-show-adjustments')),
    );
    await tester.pumpAndSettle();
    expect(api.ledgerQueries.last['includeWeightAdjustments'], isTrue);
    expect(api.ledgerQueries.last['warehouseId'], 'w1');
    final table = find.byKey(const Key('stock-item-ledger-table'));
    await tester.tap(
      find.descendant(of: table, matching: find.textContaining(' ~ ')).last,
    );
    await tester.pumpAndSettle();
    expect(find.text('选择流水日期范围'), findsOneWidget);
    await tester.tap(find.text('1'));
    await tester.pump();
    await tester.tap(find.text('1'));
    await tester.pump();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(
      api.ledgerQueries.last['dateFrom'],
      api.ledgerQueries.last['dateTo'],
    );
    expect(api.ledgerQueries.last['warehouseId'], 'w1');
    expect(api.ledgerQueries.last['colorNull'], isTrue);
    tester
        .widget<MasterDataTableView<StockLedgerRow>>(table)
        .onFilterChanged('search.billNo', 'SS-001');
    await tester.pumpAndSettle();
    expect(api.ledgerQueries.last['search.billNo'], 'SS-001');
    expect(api.ledgerQueries.last['warehouseId'], 'w1');
    expect(api.ledgerQueries.last['colorNull'], isTrue);
  });

  testWidgets(
    'count submitter goes to inventory approval mode without calling retired adjustment APIs',
    (tester) async {
      final api = await _pump(
        tester,
        permissions: const {Perm.stockView, Perm.stockCountSubmit},
        withNavigation: true,
      );
      await tester.tap(find.byKey(const ValueKey('balance-count-b1')));
      await tester.pumpAndSettle();
      expect(find.text('即时库存盘点目标页'), findsOneWidget);
      expect(
        api.posts.where(
          (post) =>
              post.$1 == '/stock/weight/balances/set' ||
              post.$1 == '/stock/balances/adjust',
        ),
        isEmpty,
      );
    },
  );

  testWidgets('weight learning card, permission-gated buttons and record '
      'statuses', (tester) async {
    final api = await _pump(
      tester,
      initialSegment: GoodsStockLedgerSegment.weight,
    );

    expect(find.text('当前单重 2.312 g/个'), findsOneWidget);
    expect(find.textContaining('依据 称重学习 23 次(有效21)'), findsOneWidget);
    // 只有 stock:view: 不能称样、不能设定单重, 看不到供应商与设置。
    expect(find.byKey(const ValueKey('goods-weight-sample')), findsNothing);
    expect(find.byKey(const ValueKey('goods-weight-set-manual')), findsNothing);
    expect(find.text('各供应商'), findsNothing);
    expect(find.text('学习设置'), findsNothing);
    for (final status in ['正常', '已排除', '已红冲', '离群']) {
      expect(find.text(status), findsOneWidget);
    }
    // 服务端 sourceDocCleared = true: 单号列显示「来源单据已清空」, 不能点回源单。
    expect(find.text('来源单据已清空'), findsOneWidget);
    expect(find.text('PR-001'), findsNothing);
    // 单重列用服务端给的本条单重。
    expect(find.text('2.31 g'), findsNWidgets(4));
    await tester.ensureVisible(find.text('单重'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('单重'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('uten-column-keyword-input')),
      '2.31 g',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(api.weightQueries.last['search.unitWeight'], '2.31 g');
    expect(api.weightQueries.last['page'], 1);
  });

  testWidgets('weight managers get sampling, manual weight, reset, '
      'suppliers and settings', (tester) async {
    await _pump(
      tester,
      permissions: const {Perm.stockView, Perm.stockWeightManage},
      initialSegment: GoodsStockLedgerSegment.weight,
    );
    expect(find.byKey(const ValueKey('goods-weight-sample')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('goods-weight-set-manual')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('goods-weight-reset-regime')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('weight-observation-toggle-o2')),
      findsOneWidget,
    );
    expect(find.text('恢复'), findsOneWidget);

    await tester.tap(find.text('各供应商'));
    await tester.pumpAndSettle();
    expect(find.text('甲五金'), findsOneWidget);
    expect(find.text('-0.5%'), findsOneWidget);

    await tester.tap(find.text('学习设置'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('weight-settings-save')), findsOneWidget);
    expect(find.text('参与学习'), findsOneWidget);
  });
}
