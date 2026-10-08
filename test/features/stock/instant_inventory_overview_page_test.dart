import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/router/route_access_policy.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/stock/models/instant_inventory_scope.dart';
import 'package:uten_imp/features/stock/pages/instant_inventory_overview_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import 'instant_inventory_test_fixture.dart';

const _scope = InstantInventoryScope(
  categoryId: 'category-1',
  warehouseId: 'warehouse-1',
  includeDefective: true,
  includeLineSide: true,
  keyword: '端子 & 螺丝',
  owningWarehouseNull: true,
  colorId: 'color-1',
  series: 'GD',
  unitId: 'unit-1',
);

void main() {
  testWidgets('总览直达和刷新重建全部筛选，风险明细使用相同范围', (tester) async {
    final api = _api();
    final router = await _pump(tester, api: api, scope: _scope);

    expect(find.text('库存总览与分析'), findsOneWidget);
    expect(api.inventoryRequests, hasLength(2));
    final summary = api.inventoryRequests.first;
    final risk = api.inventoryRequests.last;
    _expectScope(summary);
    _expectScope(risk);
    expect(summary['size'], 1);
    expect(summary['attention'], isNull);
    expect(risk['size'], 8);
    expect(risk['attention'], 'NEGATIVE_BALANCE');
    expect(risk['sort'], 'negativeBalanceCount');
    expect(risk['order'], 'desc');
    expect(find.text('900'), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);

    await tester.tap(find.byKey(const Key('inventory-overview-refresh')));
    await tester.pumpAndSettle();
    expect(api.inventoryRequests, hasLength(4));
    for (final request in api.inventoryRequests) {
      _expectScope(request);
    }
    expect(router.state.uri.queryParameters['keyword'], '端子 & 螺丝');

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, RouteName.stockInstantInventory);
    expect(find.text('即时库存返回页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('切换风险后忽略迟到的旧清单，刷新使旧请求失效', (tester) async {
    final api = _api();
    await _pump(tester, api: api);
    final oldRisk = Completer<Map<String, dynamic>>();
    api.onInventory = (query) async {
      if (query['attention'] == 'AWAITING_STOCK_IN') return oldRisk.future;
      if (query['attention'] == 'UNKNOWN_WEIGHT') {
        return _riskResponse('重量待核货品');
      }
      return api.response();
    };

    await _selectRisk(tester, 'AWAITING_STOCK_IN', settle: false);
    expect(api.inventoryRequests.last['attention'], 'AWAITING_STOCK_IN');
    await _selectRisk(tester, 'UNKNOWN_WEIGHT');
    expect(find.text('重量待核货品'), findsOneWidget);
    oldRisk.complete(_riskResponse('迟到的待入库货品'));
    await tester.pumpAndSettle();
    expect(find.text('重量待核货品'), findsOneWidget);
    expect(find.text('迟到的待入库货品'), findsNothing);

    final beforeRefresh = Completer<Map<String, dynamic>>();
    api.onInventory = (query) async => query['attention'] == 'AWAITING_STOCK_IN'
        ? beforeRefresh.future
        : api.response();
    await _selectRisk(tester, 'AWAITING_STOCK_IN', settle: false);
    api.onInventory = (query) async =>
        query['attention'] == null ? api.response() : _riskResponse('刷新后的货品');
    await tester.tap(find.byKey(const Key('inventory-overview-refresh')));
    await tester.pumpAndSettle();
    beforeRefresh.complete(_riskResponse('刷新前的旧货品'));
    await tester.pumpAndSettle();
    expect(find.text('刷新后的货品'), findsOneWidget);
    expect(find.text('刷新前的旧货品'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('缺失分析指标保留未知，不发起风险查询或显示零风险', (tester) async {
    final api = InstantInventoryApiFixture(
      withTotals: true,
      withAnalysis: false,
    );
    await _pump(tester, api: api);

    expect(api.inventoryRequests, hasLength(1));
    expect(find.text('当前可查看汇总，分析指标暂未提供'), findsOneWidget);
    expect(find.text('当前规则未发现优先处理事项'), findsNothing);
    expect(find.text('900'), findsOneWidget);
    expect(find.text('暂无覆盖率'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空范围只查询汇总，不误报旧服务端或生成风险图', (tester) async {
    final api = _api();
    api.onInventory = (_) async => {
      'items': <Object?>[],
      'totals': <Object?>[],
      'page': 1,
      'size': 1,
      'total': 0,
      'totalPages': 0,
    };
    await _pump(tester, api: api, scope: _scope);

    expect(api.inventoryRequests, hasLength(1));
    expect(api.inventoryRequests.single['attention'], isNull);
    expect(find.text('当前筛选范围暂无货品'), findsOneWidget);
    expect(find.text('返回即时库存调整筛选'), findsOneWidget);
    expect(find.text('当前可查看汇总，分析指标暂未提供'), findsNothing);
    expect(find.text('库存结构'), findsNothing);
    expect(find.byKey(const Key('inventory-risk-details')), findsNothing);
    expect(find.textContaining('最近更新'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('风险端点404明确显示未支持，不降级为未筛选库存', (tester) async {
    final api = _api();
    api.onInventory = (query) async {
      if (query['attention'] != null) {
        throw ApiException('NOT_FOUND', '资源不存在', httpStatus: 404);
      }
      return api.response();
    };
    await _pump(tester, api: api);

    expect(api.inventoryRequests, hasLength(2));
    expect(api.inventoryRequests.first['attention'], isNull);
    expect(api.inventoryRequests.last['attention'], 'NEGATIVE_BALANCE');
    expect(find.text('当前系统版本暂不支持风险明细，请联系管理员更新系统后重试。'), findsOneWidget);
    expect(find.text('重试加载清单'), findsOneWidget);
    expect(find.text('900'), findsOneWidget);
    expect(find.text('螺丝'), findsNothing);
    expect(find.text('包装箱'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('风险请求失败清除旧行并可重试，总览失败不冒充当前统计', (tester) async {
    final api = _api();
    await _pump(tester, api: api);
    api.onInventory = (_) async => throw StateError('查询失败');
    await _selectRisk(tester, 'UNKNOWN_WEIGHT');
    expect(find.text('重试加载清单'), findsOneWidget);
    expect(find.text('螺丝'), findsNothing);
    api.onInventory = (_) async => _riskResponse('重试成功货品');
    await tester.ensureVisible(find.text('重试加载清单'));
    await tester.tap(find.text('重试加载清单'));
    await tester.pumpAndSettle();
    expect(find.text('重试成功货品'), findsOneWidget);

    api.onInventory = (_) async => throw StateError('统计失败');
    await tester.tap(find.byKey(const Key('inventory-overview-refresh')));
    await tester.pumpAndSettle();
    expect(find.text('重新加载'), findsOneWidget);
    expect(find.text('900'), findsNothing);
    expect(find.text('重试成功货品'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏与放大字号可以查看建议、清单、单位统计和算法', (tester) async {
    await _pump(
      tester,
      api: _api(),
      size: const Size(375, 812),
      textScale: 1.5,
    );
    expect(find.text('库存总览与分析'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _selectRisk(tester, 'UNKNOWN_WEIGHT');
    final riskTitle = find.text('库存重量待完善清单');
    expect(riskTitle, findsOneWidget);
    final titleTop = tester.getTopLeft(riskTitle).dy;
    expect(titleTop, greaterThan(0));
    expect(titleTop, lessThan(812));
    for (final target in [
      find.byKey(const Key('inventory-risk-details')),
      find.text('按单位统计'),
      find.text('计算口径与分析边界'),
    ]) {
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    await tester.tap(find.text('计算口径与分析边界'));
    await tester.pumpAndSettle();
    expect(find.textContaining('覆盖率不是称重准确率'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('进阶分析入口单独受报表权限控制，跳转保留总览页', (tester) async {
    await _pump(tester, api: _api());
    expect(find.text('打开库存分析'), findsNothing);
    final router = await _pump(
      tester,
      api: _api(),
      permissions: {Perm.stockView, Perm.stockReportView},
    );
    await tester.ensureVisible(find.text('打开库存分析'));
    await tester.tap(find.text('打开库存分析'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, RouteName.warehouseInsights);
    router.pop();
    await tester.pumpAndSettle();
    expect(find.byType(InstantInventoryOverviewPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('总览深链仅需库存查看权限，报表权限不能替代库存查看', () {
    const ordinary = AppUser(id: 'ordinary', code: 'O', name: '普通员工');
    const stock = AppUser(
      id: 'stock',
      code: 'S',
      name: '库存查看',
      permissions: [Perm.stockView],
    );
    const report = AppUser(
      id: 'report',
      code: 'R',
      name: '库存报表',
      permissions: [Perm.stockReportView],
    );
    const path = '/stock/instant-inventory/overview';
    expect(employeePermissionRedirect(ordinary, path), RouteName.accessDenied);
    expect(employeePermissionRedirect(stock, path), isNull);
    expect(employeePermissionRedirect(report, path), RouteName.accessDenied);
  });
}

InstantInventoryApiFixture _api() =>
    InstantInventoryApiFixture(withTotals: true, withAnalysis: true);

void _expectScope(Map<String, dynamic> query) {
  expect(query['categoryId'], 'category-1');
  expect(query['warehouseId'], 'warehouse-1');
  expect(query['includeDefective'], true);
  expect(query['includeLineSide'], true);
  expect(query['keyword'], '端子 & 螺丝');
  expect(query['owningWarehouseNull'], true);
  expect(query['colorId'], 'color-1');
  expect(query['series'], 'GD');
  expect(query['unitId'], 'unit-1');
}

Map<String, dynamic> _riskResponse(String name) => {
  'items': [
    {'goodsId': name, 'name': name, 'qty': 2, 'unitName': '箱'},
  ],
  'page': 1,
  'size': 8,
  'total': 1,
  'totalPages': 1,
};

Future<void> _selectRisk(
  WidgetTester tester,
  String code, {
  bool settle = true,
}) async {
  final finder = find.byKey(Key('inventory-risk-$code'));
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Future<GoRouter> _pump(
  WidgetTester tester, {
  required InstantInventoryApiFixture api,
  InstantInventoryScope scope = const InstantInventoryScope(),
  Set<String> permissions = const {Perm.stockView},
  Size size = const Size(1500, 1000),
  double textScale = 1,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final router = GoRouter(
    initialLocation: Uri(
      path: '/stock/instant-inventory/overview',
      queryParameters: scope.toQuery(),
    ).toString(),
    routes: [
      GoRoute(
        path: '/stock/instant-inventory/overview',
        builder: (_, state) => InstantInventoryOverviewPage(
          scope: InstantInventoryScope.fromQuery(state.uri.queryParameters),
        ),
      ),
      GoRoute(
        path: RouteName.stockInstantInventory,
        builder: (_, _) => const Scaffold(body: Text('即时库存返回页')),
      ),
      GoRoute(
        path: RouteName.warehouseInsights,
        builder: (_, _) => const Scaffold(body: Text('进阶库存分析页')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentPermissionsProvider.overrideWithValue(permissions),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}
