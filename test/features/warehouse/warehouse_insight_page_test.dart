// 库存分析页契约 (ADR-135 §6.4, review/product.md §1.6):
//  1. 打开即取 /health (概览 KPI + 呆滞与库龄) 与 /cycle-count (今日建议盘点数), 按仓库范围带参
//     (warehouseId / warehouseScope=MINE, 与服务端同名); 重量按显示单位换算, 估算带「≈」, 没称显示「未称」;
//  2. KPI 卡点一下跳到对应分段并带上筛选 (呆滞品项 -> onlyDead);
//  3. 盘点建议 (仓库 x 货品 x 颜色) 勾了多个仓: 先问盘哪个仓, 带 StockCheckPrefill (含颜色) 打开新建
//     盘点单, 其余仓勾选保留;
//  4. 称重异常: 类别/折算/偏差用服务端算好的值, 可切「按往来方汇总」(服务端 WeightPartySummary);
//  5. 单重学习批量称样: 抽样数量 + 抽样重量(g) -> POST samples, 行上立即换成新单重。
// 假回包字段与服务端 DTO 一一对应。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/warehouse/models/stock_check_prefill.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_insight_page.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_insight_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/measurement/weight_prefs.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/warehouse/warehouse_task_scope.dart';

class _MemoryWeightUnitsPrefs extends WarehouseWeightUnitsPrefsNotifier {
  @override
  WeightUnitsPrefs build() => const WeightUnitsPrefs();

  @override
  void persist() {}
}

class _FakeApi extends ApiClient {
  _FakeApi() : super(Dio());

  final gets = <(String, Map<String, dynamic>)>[];
  final posts = <(String, Object?)>[];

  List<Map<String, dynamic>> queriesOf(String path) => [
    for (final g in gets)
      if (g.$1 == path) g.$2,
  ];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    gets.add((path, {...?query}));
    return switch (path) {
      '/stock/insights/health' => _health,
      '/stock/insights/cycle-count' => _cycle,
      '/stock/insights/weight-alerts' => _alerts,
      '/stock/insights/learning' => _learning,
      _ => const {},
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    posts.add((path, body));
    if (path.endsWith('/samples')) {
      return {
        'goodsId': 'g-l1',
        'resolved': {
          'key': 'g-l1|',
          'basis': 'LEARNED',
          'evidence': 'REFERENCE',
          'unitWeightKg': 0.00231,
          'tier': 'YELLOW',
          'nInliers': 1,
        },
      };
    }
    return const {};
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async =>
      const {};
}

// 以下回包与服务端 DTO 字段一一对应 (WarehouseHealthPage / CycleCountRow / WeightAlertPage /
// WeightPartySummary / LearningRow), 分页平铺、页码从 1 起。
const _health = <String, dynamic>{
  'overview': {
    'skuWithStock': 120,
    'knownWeightKg': 830.5,
    'weightUnknownRows': 4,
    'weighedCoveragePct': 35,
    'deadSku': 7,
    'aged180QtyPct': 18.25,
    'movements30d': 260,
    'alerts30d': 5,
    'receiptShort30d': 3,
    'drawOver30d': 2,
    'needsSample': 11,
    'deadAmountLocal': null,
  },
  'items': [
    {
      'goodsId': 'g1',
      'code': 'SC-001',
      'name': '螺丝M3',
      'colorId': 'c-black',
      'colorName': '黑',
      'unitName': '个',
      'qty': 5000,
      'weightKg': 12.5,
      'weightEstimated': true,
      'idleDays': 120,
      'abc': 'C',
      'dead': false,
      'amountLocal': null,
      'costMasked': true,
    },
    {
      'goodsId': 'g2',
      'code': 'PL-002',
      'name': '胶粒ABS',
      'colorId': null,
      'unitName': '包',
      'qty': 3,
      'weightKg': null,
      'weightEstimated': false,
      'abc': 'N',
      'dead': true,
      'amountLocal': null,
      'costMasked': true,
    },
  ],
  'page': 1,
  'size': 50,
  'total': 2,
  'totalPages': 1,
  // 服务端合计键: qty (按单位) / weightKg + weightKg_unknown_rows + weightKg_estimated_rows / out90。
  'totals': [
    {
      'key': 'qty',
      'label': '合计库存数量',
      'type': 'number',
      'groupKey': 'unitName',
      'groups': [
        {'unit': '个', 'value': 5000},
        {'unit': '包', 'value': 3},
      ],
    },
    {
      'key': 'weightKg',
      'label': '合计库存重量',
      'type': 'weight',
      'groupKey': null,
      'groups': [
        {'unit': null, 'value': 12.5},
      ],
    },
    {
      'key': 'weightKg_unknown_rows',
      'label': '重量未知',
      'type': 'count',
      'groupKey': null,
      'groups': [
        {'unit': null, 'value': 1},
      ],
    },
    {
      'key': 'weightKg_estimated_rows',
      'label': '重量含估算',
      'type': 'count',
      'groupKey': null,
      'groups': [
        {'unit': null, 'value': 1},
      ],
    },
  ],
};

const _cycle = <String, dynamic>{
  'items': [
    {
      'warehouseId': 'wh-hw',
      'warehouseName': '五金仓库',
      'goodsId': 'g1',
      'code': 'SC-001',
      'name': '螺丝M3',
      'colorId': null,
      'colorName': null,
      'unitName': '个',
      'abc': 'A',
      'daysSince': 45,
      'reasons': ['DUE', 'RESIDUAL'],
      'score': 2.4,
      'qty': 5000,
      'weightKg': 12.5,
      'weightEstimated': true,
    },
    {
      'warehouseId': 'wh-hw',
      'warehouseName': '五金仓库',
      'goodsId': 'g3',
      'code': 'NT-003',
      'name': '螺母M3',
      'colorId': 'c-white',
      'colorName': '白',
      'unitName': '个',
      'abc': 'B',
      'daysSince': 20,
      'reasons': ['RED_TIER'],
      'score': 0.5,
      'qty': 800,
      'weightKg': null,
      'weightEstimated': false,
    },
    {
      'warehouseId': 'wh-pl',
      'warehouseName': '塑胶仓库',
      'goodsId': 'g2',
      'code': 'PL-002',
      'name': '胶粒ABS',
      'colorId': null,
      'colorName': null,
      'unitName': '包',
      'abc': 'N',
      'daysSince': 30,
      'reasons': ['UNKNOWN_WEIGHT'],
      'score': 1.1,
      'qty': 3,
      'weightKg': null,
      'weightEstimated': false,
    },
  ],
  'page': 1,
  'size': 50,
  'total': 3,
  'totalPages': 1,
};

const _alerts = <String, dynamic>{
  'items': [
    {
      'rowType': 'OBSERVATION',
      'id': 'o1',
      'observedAt': '2026-09-20T02:00:00Z',
      'alertKind': 'RECEIPT_SHORT',
      'alertLabel': '来料少数',
      'goodsId': 'g1',
      'code': 'SC-001',
      'name': '螺丝M3',
      'unitName': '个',
      'baseUnitDimension': 'COUNT',
      'sourceKind': 'RECEIPT',
      'supplierId': 's1',
      'supplierName': '东莞五金厂',
      'sourceDocType': 'PURCHASE_RECEIPT',
      'sourceDocId': 'pr-1',
      'billNo': 'PR-0001',
      'qtyBase': 5000,
      'weightKg': 11.0,
      'expectedUnitWeightKg': 0.00231,
      'expectedWeightKg': 11.55,
      'estimatedQty': 4761.9,
      'deviationQty': -238.1,
      'deviationPct': -4.8,
      'alertLevel': 'ALERT',
      'estimateTierUsed': 'YELLOW',
      'estimateBasisUsed': 'LEARNED',
    },
    {
      'rowType': 'REGIME',
      'id': 'e1',
      'observedAt': '2026-09-18T02:00:00Z',
      'alertKind': 'REGIME_CHANGE',
      'alertLabel': '单重可能已变化(换批/换料?)',
      'goodsId': 'g3',
      'code': 'NT-003',
      'name': '螺母M3',
      'unitName': '个',
      'baseUnitDimension': 'COUNT',
      'estimateTierUsed': 'RED',
      'unitWeightKg': 0.0012,
    },
  ],
  'page': 1,
  'size': 50,
  'total': 2,
  'totalPages': 1,
  'supplierSummary': [
    {
      'partyId': 's1',
      'partyName': '东莞五金厂',
      'events': 9,
      'flagged': 3,
      'avgPct': -2.6,
      'kg': 1.2,
    },
  ],
  'workshopSummary': [
    {
      'partyId': 'd1',
      'partyName': '注塑车间',
      'events': 12,
      'flagged': 2,
      'avgPct': 1.9,
      'kg': 0.8,
    },
  ],
};

const _learning = <String, dynamic>{
  'items': [
    {
      'goodsId': 'g-l1',
      'code': 'SC-009',
      'name': '垫片M5',
      'model': null,
      'unitName': '个',
      'baseUnitDimension': 'COUNT',
      'basis': 'NONE',
      'suggestedSampleSize': 20,
      'movements90d': 6,
      'observations': 0,
      'learningEnabled': true,
      'stale': false,
    },
    {
      'goodsId': 'g-l2',
      'code': 'PL-010',
      'name': '色母粒',
      'unitName': '个',
      'baseUnitDimension': 'COUNT',
      'basis': 'LEARNED',
      'evidence': 'DRAW_ONLY',
      'tier': 'YELLOW',
      'unitWeightKg': 0.5,
      'nInliers': 0,
      'nRef': 0,
      'nDraw': 12,
      'movements90d': 4,
      'observations': 12,
      'learningEnabled': true,
      'stale': false,
    },
  ],
  'page': 1,
  'size': 50,
  'total': 2,
  'totalPages': 1,
};

late SharedPreferences _preferences;

class _Nav {
  final locations = <String>[];
  Object? lastExtra;
}

Future<(_FakeApi, _Nav)> _open(
  WidgetTester tester, {
  Set<String> permissions = const {
    Perm.stockReportView,
    Perm.stockView,
    Perm.stockDocView,
    Perm.stockDocCreate,
    Perm.warehouseInboundStockIn,
  },
  String initial = '/warehouse/insights',
}) async {
  tester.view.physicalSize = const Size(1800, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final api = _FakeApi();
  final nav = _Nav();
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(
        path: '/warehouse/insights',
        builder: (_, s) => WarehouseInsightPage(
          initialSegment: s.uri.queryParameters['segment'],
        ),
      ),
      GoRoute(
        path: '/warehouse/:code/new',
        builder: (_, s) {
          nav.locations.add(s.uri.toString());
          nav.lastExtra = s.extra;
          return const Scaffold(body: Text('新建盘点单页'));
        },
      ),
      GoRoute(
        path: '/stock/item/:goodsId',
        builder: (_, s) {
          nav.locations.add(s.uri.toString());
          return const Scaffold(body: Text('库存详情页'));
        },
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(_preferences),
        apiClientProvider.overrideWithValue(api),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        myWarehouseScopeProvider.overrideWith(
          (ref) async => const MyWarehouseScope(
            role: WarehouseScopeRole.supervisor,
            canSelectAll: true,
            selectable: [
              WarehouseScopeOption(id: 'wh-hw', name: '五金仓库'),
              WarehouseScopeOption(id: 'wh-pl', name: '塑胶仓库'),
            ],
          ),
        ),
        warehouseWeightUnitsPrefsProvider.overrideWith(
          _MemoryWeightUnitsPrefs.new,
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return (api, nav);
}

Finder _inKpis(String text) => find.descendant(
  of: find.byKey(const Key('insight-kpis')),
  matching: find.text(text),
);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });

  testWidgets('opens with KPIs, health table and weight display rules', (
    tester,
  ) async {
    final (api, _) = await _open(tester);

    final health = api.queriesOf('/stock/insights/health');
    expect(health, isNotEmpty);
    expect(health.first['page'], 1);
    expect(health.first['size'], 50);
    // 非负责人默认「全部仓库」: 不带范围参数。
    expect(health.first.containsKey('warehouseId'), isFalse);
    expect(health.first.containsKey('warehouseScope'), isFalse);
    expect(api.queriesOf('/stock/insights/cycle-count'), isNotEmpty);

    expect(_inKpis('7'), findsOneWidget); // 呆滞品项
    expect(_inKpis('18.3'), findsOneWidget); // 库龄超180天 %
    expect(_inKpis('3'), findsOneWidget); // 今日建议盘点
    expect(_inKpis('5'), findsOneWidget); // 近30天称重异常
    expect(_inKpis('11'), findsOneWidget); // 待称样货品
    // 说明行随 /health 概览下发, 不用等称重异常分段加载。
    expect(_inKpis('来料少数 3 / 领料超发 2'), findsOneWidget);
    expect(api.queriesOf('/stock/insights/weight-alerts'), isEmpty);

    expect(find.text('螺丝M3'), findsOneWidget);
    expect(find.text('≈12.5 kg'), findsOneWidget);
    expect(find.text('未称'), findsOneWidget);
    expect(find.text('无消耗'), findsOneWidget);
    // 没有成本权限 (costMasked): 不出库存金额列。
    expect(find.text('库存金额'), findsNothing);
    // 合计条: 重量伴随项并进重量项 (估算带「≈」, 未称行数另注), 不单独占位。
    expect(find.textContaining('≈12.5 kg (另有 1 项未称)'), findsOneWidget);
    expect(find.textContaining('重量未知'), findsNothing);
  });

  test('scope maps to scopeWarehouseId like the task endpoints (ADR-149)', () {
    expect(
      WarehouseInsightRepository.scopeQuery(const WarehouseTaskScope.all()),
      isEmpty,
    );
    expect(
      WarehouseInsightRepository.scopeQuery(
        const WarehouseTaskScope.warehouse('wh-hw'),
      ),
      {'scopeWarehouseId': 'wh-hw'},
    );
  });

  testWidgets('tapping the dead-stock KPI filters the health segment', (
    tester,
  ) async {
    final (api, _) = await _open(tester);
    await tester.tap(find.text('呆滞品项 (≥90天无消耗)'));
    await tester.pumpAndSettle();

    expect(api.queriesOf('/stock/insights/health').last['onlyDead'], isTrue);
    final chip = tester.widget<FilterChip>(
      find.byKey(const Key('insight-only-dead')),
    );
    expect(chip.selected, isTrue);
  });

  testWidgets(
    'cycle count asks which warehouse, then opens a prefilled CHECK',
    (tester) async {
      final (_, nav) = await _open(tester);
      await tester.tap(find.text('盘点建议'));
      await tester.pumpAndSettle();
      expect(find.text('到期、近期尾差'), findsOneWidget);
      expect(find.text('高'), findsOneWidget);
      // 一行 = 一条盘点明细 (仓库 x 货品 x 颜色)。
      expect(find.text('白'), findsOneWidget);

      for (final name in ['螺丝M3', '螺母M3', '胶粒ABS']) {
        await tester.tap(find.text(name));
        await tester.pumpAndSettle();
      }
      expect(find.text('生成盘点单(3)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('insight-generate-check')));
      await tester.pumpAndSettle();

      // 勾了两个仓: 先问盘哪个仓。
      expect(find.text('先为哪个仓库生成盘点单?'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('insight-check-warehouse-wh-hw')),
      );
      await tester.pumpAndSettle();

      expect(nav.locations.last, '/warehouse/CHECK/new');
      final prefill = nav.lastExtra as StockCheckPrefill;
      expect(prefill.warehouseId, 'wh-hw');
      expect(
        [for (final l in prefill.lines) '${l.goodsId}|${l.colorId}'],
        ['g1|null', 'g3|c-white'],
      );
      expect(find.text('新建盘点单页'), findsOneWidget);

      // 回来后塑胶仓那一行的勾选还在, 直接再生成 (只剩一个仓就不再问)。
      GoRouter.of(tester.element(find.text('新建盘点单页'))).pop();
      await tester.pumpAndSettle();
      expect(find.text('生成盘点单(1)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('insight-generate-check')));
      await tester.pumpAndSettle();
      expect(find.text('先为哪个仓库生成盘点单?'), findsNothing);
      final second = nav.lastExtra as StockCheckPrefill;
      expect(second.warehouseId, 'wh-pl');
      expect(second.lines.single.goodsId, 'g2');
    },
  );

  testWidgets('weight alerts show kinds and can group by counterpart', (
    tester,
  ) async {
    final (api, _) = await _open(tester);
    await tester.tap(find.text('称重异常'));
    await tester.pumpAndSettle();

    expect(api.queriesOf('/stock/insights/weight-alerts').last['days'], 30);
    // 类别文案、折算数量与偏差都用服务端算好的值 (按件计取整)。
    expect(find.text('来料少数'), findsOneWidget);
    expect(find.text('单重可能已变化(换批/换料?)'), findsOneWidget);
    expect(find.text('东莞五金厂'), findsOneWidget);
    expect(find.text('≈4,762个'), findsOneWidget);
    expect(find.text('少约238个 (-4.8%)'), findsOneWidget);

    await tester.tap(find.byKey(const Key('insight-group-by-counterpart')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('insight-counterpart-table')), findsOneWidget);
    expect(find.text('供应商来料'), findsOneWidget);
    expect(find.text('注塑车间'), findsOneWidget);
    expect(find.text('少 2.6%'), findsOneWidget);
    expect(find.text('多 1.9%'), findsOneWidget);
  });

  testWidgets('learning batch sample saves and refreshes the row', (
    tester,
  ) async {
    final (api, _) = await _open(
      tester,
      initial: '/warehouse/insights?segment=learning',
    );
    expect(
      api.queriesOf('/stock/insights/learning').last['filter'],
      'NEEDS_SAMPLE',
    );
    expect(find.text('暂无单重'), findsOneWidget);
    // 按过往领料推算的依据次数来自服务端 nDraw。
    expect(find.text('按过往领料推算 (领料12次)'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('insight-sample-qty-g-l1')),
      '20',
    );
    await tester.enterText(
      find.byKey(const ValueKey('insight-sample-weight-g-l1')),
      '46.2',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('insight-sample-save-g-l1')));
    await tester.pumpAndSettle();

    final (path, body) = api.posts.single;
    expect(path, '/stock/weight/goods/g-l1/samples');
    final json = body! as Map<String, Object?>;
    expect(json['qty'], 20);
    expect(json['weight'], 46.2);
    expect(json['weightUnit'], 'G');
    expect(json['idempotencyKey'], startsWith('weight-sample-'));

    expect(find.text('2.31 g'), findsOneWidget);
    expect(find.text('近1次称重'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('insight-sample-saved-g-l1')),
      findsOneWidget,
    );
  });

  testWidgets('learning save validates whole pieces before posting', (
    tester,
  ) async {
    final (api, _) = await _open(
      tester,
      initial: '/warehouse/insights?segment=learning',
    );
    await tester.enterText(
      find.byKey(const ValueKey('insight-sample-qty-g-l1')),
      '2.5',
    );
    await tester.enterText(
      find.byKey(const ValueKey('insight-sample-weight-g-l1')),
      '5g',
    );
    await tester.tap(find.byKey(const ValueKey('insight-sample-save-g-l1')));
    await tester.pumpAndSettle();
    expect(api.posts, isEmpty);
    // 校验提示收进输入框内的提示图标 (UtenInputDecoration + UtenFieldMessage)。
    final hint = tester.widget<UtenFieldHintIcon>(
      find.descendant(
        of: find.byKey(const ValueKey('insight-sample-weight-g-l1')),
        matching: find.byType(UtenFieldHintIcon),
      ),
    );
    expect(hint.errorMessage, '按件计的抽样数量要填整数');
  });

  testWidgets('learning filter chips include the server CONFLICT filter', (
    tester,
  ) async {
    final (api, _) = await _open(
      tester,
      initial: '/warehouse/insights?segment=learning',
    );
    await tester.tap(find.byKey(const ValueKey('insight-learning-CONFLICT')));
    await tester.pumpAndSettle();
    expect(
      api.queriesOf('/stock/insights/learning').last['filter'],
      'CONFLICT',
    );
  });
}
