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
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/measurement/weight_prefs.dart';
import 'package:uten_imp/shared/stock_ledger/goods_stock_ledger_panel.dart';
import 'package:uten_imp/shared/stock_ledger/stock_ledger_models.dart';

class _MemoryWeightUnitsPrefs extends WarehouseWeightUnitsPrefsNotifier {
  @override
  WeightUnitsPrefs build() => const WeightUnitsPrefs();

  @override
  void persist() {}
}

class _PanelApi extends ApiClient {
  _PanelApi() : super(Dio());

  final ledgerQueries = <Map<String, dynamic>>[];
  final posts = <(String, Object?)>[];
  int balanceCalls = 0;

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('warehouses/dict')) {
      return [
        {'id': 'w1', 'name': '五金仓库'},
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
        {'id': 'g1', 'name': '螺丝', 'code': 'S-001', 'unitId': 'u1'},
      ];
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    switch (path) {
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
        return {
          'items': [
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
            'key': 'g1|',
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
            'key': 'g1|',
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
}) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final api = _PanelApi();
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
      child: MaterialApp(
        home: Scaffold(
          body: GoodsStockLedgerPanel(
            goodsId: 'g1',
            initialSegment: initialSegment,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('balance segment shows KPI, estimated and unknown weights, '
      'and actions by permission', (tester) async {
    await _pump(tester);

    expect(find.textContaining('库存 12,500'), findsOneWidget);
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
  });

  testWidgets('weight managers and balance adjusters see their actions', (
    tester,
  ) async {
    await _pump(
      tester,
      permissions: const {
        Perm.stockView,
        Perm.stockBalanceAdjust,
        Perm.stockWeightManage,
      },
    );
    expect(find.byKey(const ValueKey('balance-adjust-b1')), findsOneWidget);
    expect(find.byKey(const ValueKey('balance-weigh-b1')), findsOneWidget);
  });

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
  });

  testWidgets('weigh posts a manual balance weight in kg with the current '
      'weight as the optimistic check', (tester) async {
    final api = await _pump(
      tester,
      permissions: const {Perm.stockView, Perm.stockWeightManage},
    );
    final balanceCallsBefore = api.balanceCalls;

    await tester.tap(find.byKey(const ValueKey('balance-weigh-b1')));
    await tester.pumpAndSettle();
    expect(find.text('核重'), findsWidgets);

    await tester.enterText(
      find.byKey(const ValueKey('stock-balance-target-weight')),
      '850g',
    );
    await tester.enterText(
      find.byKey(const ValueKey('stock-balance-reason')),
      '整批过磅',
    );
    await tester.tap(find.byKey(const ValueKey('stock-balance-submit')));
    await tester.pumpAndSettle();

    final post = api.posts.lastWhere(
      (p) => p.$1 == '/stock/weight/balances/set',
    );
    final body = post.$2! as Map<String, Object?>;
    expect(body['warehouseId'], 'w1');
    expect(body['goodsId'], 'g1');
    expect(body['colorId'], 'c1');
    expect(body['targetWeightKg'], 0.85);
    expect(body['expectedWeightKg'], 11.55);
    expect(body['reason'], '整批过磅');
    expect(body['idempotencyKey'], startsWith('stock-balance-weigh-'));
    // 核重成功后余额重新取。
    expect(api.balanceCalls, greaterThan(balanceCallsBefore));
  });

  testWidgets('weight learning card, permission-gated buttons and record '
      'statuses', (tester) async {
    await _pump(tester, initialSegment: GoodsStockLedgerSegment.weight);

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
