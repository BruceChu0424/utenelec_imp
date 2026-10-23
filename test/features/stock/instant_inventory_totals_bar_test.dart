// 即时库存页「精简合计与详情」契约。
//
// 一行 = 一个货品×颜色跨仓聚合，所以合计必须与表格**同一批行**（同一分类/仓库/含不良品仓/
// 关键字筛选）在**整个结果集**上算，而不是对当前这一页求和。
//
// 当前页只有 10 个 / 2 箱，全集 137 行则有 900 个 / 20 箱。
// 主界面只留重量与入口，详细数量必须仍来自服务端全集且按单位分别展示。
import 'dart:async';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/buttons/uten_back_button.dart';
import 'package:uten_imp/components/print/uten_print_preview.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';

import 'package:go_router/go_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/stock/models/stock_query.dart';
import 'package:uten_imp/features/stock/pages/instant_inventory_page.dart';
import 'package:uten_imp/features/stock/pages/instant_inventory_overview_page.dart';
import 'package:uten_imp/features/stock/models/instant_inventory_scope.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'instant_inventory_test_fixture.dart';
import 'package:uten_imp/features/stock/widgets/instant_inventory_summary_bar.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets('表格底部只保留服务端重量合计和详情入口', (tester) async {
    final router = await _pumpPage(tester, const Size(1500, 1000));

    expect(find.byType(InstantInventorySummaryBar), findsOneWidget);
    expect(find.text('查看详情'), findsOneWidget);

    // 数量和等待阶段移到详情，不再在表格底部铺开。
    expect(find.text('合计库存数量'), findsNothing);
    expect(find.text('合计待检量'), findsNothing);
    expect(find.text('合计合格待入库'), findsNothing);
    expect(find.textContaining('900'), findsNothing);

    // 这是 137 行全集的 3520 kg，不能退化为本页 4.5 kg。
    expect(
      find.textContaining('≈3.52 t (另有 12 项未称)', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('重量未知'), findsNothing);
    expect(find.text('重量含估算'), findsNothing);
    expect(router.state.uri.path, RouteName.stockInstantInventory);
  });

  testWidgets('点击详情查看同一筛选的全集，数量按单位分开并隐藏全零单位', (tester) async {
    await _pumpPage(tester, const Size(1500, 1000));

    await tester.tap(find.text('查看详情'));
    await tester.pumpAndSettle();

    final overview = find.byType(InstantInventoryOverviewPage);
    Finder inOverview(Finder finder) =>
        find.descendant(of: overview, matching: finder);
    expect(overview, findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(inOverview(find.text('库存总览与分析')), findsOneWidget);
    expect(inOverview(find.text('137 项')), findsOneWidget);
    expect(inOverview(find.text('当前筛选的全部结果 · 与翻页无关')), findsOneWidget);
    expect(inOverview(find.text('900')), findsOneWidget);
    expect(inOverview(find.text('20')), findsOneWidget);
    expect(inOverview(find.text('11')), findsOneWidget);
    expect(inOverview(find.text('7')), findsOneWidget);
    expect(inOverview(find.text('个')), findsOneWidget);
    expect(inOverview(find.text('箱')), findsOneWidget);
    expect(inOverview(find.text('米')), findsNothing);
    expect(inOverview(find.textContaining('920')), findsNothing);
    expect(inOverview(find.text('100 项')), findsOneWidget);
    expect(inOverview(find.text('35 项')), findsOneWidget);
    expect(inOverview(find.text('88.2%')), findsOneWidget);
    expect(inOverview(find.textContaining('3 处仓库余额为负')), findsOneWidget);
    expect(inOverview(find.textContaining('零库存不等于缺货')), findsOneWidget);

    await tester.ensureVisible(find.text('计算口径与分析边界'));
    await tester.tap(find.text('计算口径与分析边界'));
    await tester.pumpAndSettle();
    expect(inOverview(find.textContaining('覆盖率不是称重准确率')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('详情为独立路由，返回保留分类与表头筛选并清空页面搜索', (tester) async {
    final api = InstantInventoryApiFixture(
      withTotals: true,
      withAnalysis: true,
      withCategories: true,
    );
    final router = await _pumpPage(tester, const Size(1500, 1000), api: api);
    await _chooseCategory(tester, '原材料');
    final search = find.descendant(
      of: find.byKey(const Key('instant-inventory-search')),
      matching: find.byType(EditableText),
    );
    await tester.enterText(search, '原材料');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    final tableFinder = find.byType(MasterDataTableView<InstantInventoryRow>);
    tester
        .widget<MasterDataTableView<InstantInventoryRow>>(tableFinder)
        .onFilterChanged('series', 'GD');
    await tester.pumpAndSettle();
    final originalState = tester.state(find.byType(InstantInventoryPage));

    await tester.tap(find.text('查看详情'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/stock/instant-inventory/overview');
    expect(router.state.uri.queryParameters['categoryId'], isNull);
    expect(router.state.uri.queryParameters['keyword'], '原材料');
    expect(router.state.uri.queryParameters['series'], 'GD');
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(InstantInventoryOverviewPage), findsOneWidget);
    expect(api.inventoryRequests.last['categoryId'], isNull);
    expect(api.inventoryRequests.last['keyword'], '原材料');

    router.pop();
    await tester.pumpAndSettle();
    expect(router.state.uri.path, RouteName.stockInstantInventory);
    expect(
      tester.state(find.byType(InstantInventoryPage)),
      same(originalState),
    );
    expect(find.text('原材料'), findsOneWidget);
    expect(tester.widget<EditableText>(search).controller.text, isEmpty);
    expect(
      tester
          .widget<MasterDataTableView<InstantInventoryRow>>(tableFinder)
          .filters,
      {'series': 'GD'},
    );
    expect(find.byType(InstantInventorySummaryBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final (browse, selectedSearch) in [
    ('raw', null),
    (null, null),
    ('raw', 'finished'),
  ]) {
    testWidgets('行详情和概览重建分别恢复搜索范围与浏览点：$browse/$selectedSearch', (tester) async {
      final api = _NavigationApiFixture();
      final router = await _pumpPage(
        tester,
        const Size(1500, 1000),
        api: api,
        permissions: const {Perm.stockReportExport},
        initialLocation: Uri(
          path: RouteName.stockInstantInventory,
          queryParameters: InstantInventoryNavigationContext(
            scope: InstantInventoryScope(
              categoryId: browse,
              warehouseId: 'warehouse-main',
              includeDefective: true,
              includeLineSide: true,
              owningWarehouse: 'warehouse-owner',
              colorId: 'red',
              series: 'GD',
              unitId: 'unit-1',
            ),
            browseCategoryId: browse,
            returnTo: _upstreamReturnTo,
          ).toQuery(),
        ).toString(),
      );
      await tester.enterText(_inventorySearch(), '螺丝 M3');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('goods-search-related')));
      await tester.pumpAndSettle();
      if (selectedSearch != null) {
        await _chooseCategory(tester, '成品');
      }
      _expectNavigationScope(
        api.inventoryRequests.last,
        category: selectedSearch,
        keyword: '螺丝 M3',
      );
      final oldState = tester.state(find.byType(InstantInventoryPage));
      final table = tester.widget<MasterDataTableView<InstantInventoryRow>>(
        find.byType(MasterDataTableView<InstantInventoryRow>),
      );
      table.onRowTap!(table.items.first);
      await tester.pumpAndSettle();
      expect(router.state.uri.path, startsWith(RouteName.stockItemBase));
      final returnTo = router.state.uri.queryParameters['returnTo']!;
      final restored = Uri.parse(returnTo).queryParameters;
      expect(restored['categoryId'], selectedSearch);
      expect(restored['browseCategoryId'], browse ?? '');
      expect(restored['returnTo'], _upstreamReturnTo);
      expect(restored['keyword'], '螺丝 M3');
      expect(restored['includeRelated'], 'true');

      // Force the same reconstruction as refreshing a detail then following
      // its returnTo, rather than relying on the pushed page's live State.
      router.go('${RouteName.stockItemBase}/replay');
      await tester.pumpAndSettle();
      router.go(returnTo);
      await tester.pumpAndSettle();
      expect(
        tester.state(find.byType(InstantInventoryPage)),
        isNot(same(oldState)),
      );
      _expectNavigationScope(
        api.inventoryRequests.last,
        category: selectedSearch,
        keyword: '螺丝 M3',
      );
      final export = tester.widget<UtenExportButton>(
        find.byType(UtenExportButton),
      );
      _expectNavigationScope(
        export.queryParams,
        category: selectedSearch,
        keyword: '螺丝 M3',
      );
      expect(export.queryParams, isNot(contains('browseCategoryId')));
      expect(export.queryParams, isNot(contains('returnTo')));

      await tester.tap(find.text('查看详情'));
      await tester.pumpAndSettle();
      final overviewLocation = router.state.uri.toString();
      expect(router.state.uri.queryParameters['categoryId'], selectedSearch);
      expect(router.state.uri.queryParameters['returnTo'], returnTo);
      for (final request in api.inventoryRequests.reversed.take(2)) {
        _expectNavigationScope(
          request,
          category: selectedSearch,
          keyword: '螺丝 M3',
        );
      }
      // A refreshed/deep-linked overview has no list page beneath it. Its
      // standard Back button must still restore the complete page context.
      router.go('${RouteName.stockItemBase}/overview-replay');
      await tester.pumpAndSettle();
      router.go(overviewLocation);
      await tester.pumpAndSettle();
      expect(router.canPop(), isFalse);
      await tester.tap(find.byType(UtenBackButton));
      await tester.pumpAndSettle();
      _expectNavigationScope(
        api.inventoryRequests.last,
        category: selectedSearch,
        keyword: '螺丝 M3',
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('instant-inventory-search')),
          matching: find.byIcon(Icons.close_rounded),
        ),
      );
      await tester.pumpAndSettle();
      _expectNavigationScope(
        api.inventoryRequests.last,
        category: browse,
        keyword: null,
      );
      await tester.tap(find.byType(UtenBackButton));
      await tester.pumpAndSettle();
      expect(router.state.uri.toString(), _upstreamReturnTo);
      expect(tester.takeException(), isNull);
    });
  }

  for (final legacyConstructor in [false, true]) {
    testWidgets('旧URL或initialScope的分类仍是浏览点，搜索全局：$legacyConstructor', (
      tester,
    ) async {
      final api = _NavigationApiFixture();
      const legacy = InstantInventoryScope(
        categoryId: 'raw',
        keyword: '螺丝',
        includeRelated: true,
        series: 'GD',
      );
      final router = await _pumpPage(
        tester,
        const Size(1500, 1000),
        api: api,
        legacyInitialScope: legacyConstructor ? legacy : null,
        initialLocation: Uri(
          path: RouteName.stockInstantInventory,
          queryParameters: legacy.toQuery(),
        ).toString(),
      );
      expect(api.inventoryRequests.last['categoryId'], isNull);
      expect(api.inventoryRequests.last['keyword'], '螺丝');
      expect(api.inventoryRequests.last['includeRelated'], isTrue);
      expect(api.inventoryRequests.last['series'], 'GD');
      expect(
        router.state.uri.queryParameters,
        isNot(contains('browseCategoryId')),
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('instant-inventory-search')),
          matching: find.byIcon(Icons.close_rounded),
        ),
      );
      await tester.pumpAndSettle();
      expect(api.inventoryRequests.last['categoryId'], 'raw');
      expect(api.inventoryRequests.last['keyword'], isNull);
      expect(api.inventoryRequests.last['includeRelated'], isNull);
      expect(api.inventoryRequests.last['series'], 'GD');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('旧响应仍可看汇总，缺失分析指标时不显示零风险结论', (tester) async {
    await _pumpPage(tester, const Size(1500, 1000), withAnalysis: false);

    await tester.tap(find.text('查看详情'));
    await tester.pumpAndSettle();

    expect(find.text('当前可查看汇总，分析指标暂未提供'), findsOneWidget);
    expect(find.text('当前规则未发现优先处理事项'), findsNothing);
    expect(find.text('暂无覆盖率'), findsOneWidget);
    expect(find.text('900'), findsOneWidget);
    expect(find.text('20'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('后端未下发 totals 时合计条整条不渲染（不伪造 0、不退化成本页合计）', (tester) async {
    await _pumpPage(tester, const Size(1500, 1000), withTotals: false);
    expect(find.byType(InstantInventorySummaryBar), findsNothing);
    expect(find.text('查看详情'), findsNothing);
  });

  testWidgets('刷新进行中或失败时不把旧合计当作当前值，也不能打开旧分析', (tester) async {
    final api = InstantInventoryApiFixture(
      withTotals: true,
      withAnalysis: true,
    );
    await _pumpPage(tester, const Size(1500, 1000), api: api);
    final request = Completer<Map<String, dynamic>>();
    api.nextInventoryResponse = request.future;

    await tester.tap(find.byTooltip('刷新'));
    await tester.pump();

    expect(find.textContaining('统计更新中…', findRichText: true), findsOneWidget);
    expect(find.textContaining('3.52 t', findRichText: true), findsNothing);
    final details = find.byKey(const Key('instant-inventory-summary-details'));
    expect(tester.widget<TextButton>(details).onPressed, isNull);
    expect(find.byType(InstantInventoryOverviewPage), findsNothing);

    request.completeError(StateError('库存查询失败'));
    await tester.pumpAndSettle();

    expect(find.textContaining('统计暂不可用', findRichText: true), findsOneWidget);
    expect(find.textContaining('3.52 t', findRichText: true), findsNothing);
    expect(tester.widget<TextButton>(details).onPressed, isNull);
    expect(find.byType(InstantInventoryOverviewPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('防抖和结果更新期间禁旧合计，新结果完成后开放同范围汇总', (tester) async {
    final api = InstantInventoryApiFixture(
      withTotals: true,
      withAnalysis: true,
      withCategories: true,
    );
    final router = await _pumpPage(tester, const Size(1500, 1000), api: api);
    final inventory = Completer<Map<String, dynamic>>();
    api.nextInventoryResponse = inventory.future;
    final search = find.descendant(
      of: find.byKey(const Key('instant-inventory-search')),
      matching: find.byType(EditableText),
    );
    final details = find.byKey(const Key('instant-inventory-summary-details'));
    final oldDetails = tester.widget<TextButton>(details).onPressed!;

    await tester.enterText(search, '新货品');
    await tester.pump();
    expect(find.byType(InstantInventorySummaryBar), findsNothing);
    expect(details, findsNothing);
    expect(find.textContaining('3.52 t', findRichText: true), findsNothing);
    oldDetails();
    await tester.pump();
    expect(find.byType(InstantInventoryOverviewPage), findsNothing);
    expect(router.state.uri.path, RouteName.stockInstantInventory);

    await tester.pump(const Duration(milliseconds: 301));
    expect(find.byType(InstantInventorySummaryBar), findsNothing);
    expect(details, findsNothing);
    expect(find.textContaining('3.52 t', findRichText: true), findsNothing);
    oldDetails();
    await tester.pump();
    expect(find.byType(InstantInventoryOverviewPage), findsNothing);
    expect(router.state.uri.path, RouteName.stockInstantInventory);

    inventory.complete(api.response());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester.widget<TextButton>(details).onPressed,
      isNotNull,
      reason: '真实全局结果已更新，可以查看同口径汇总',
    );
    expect(find.textContaining('3.52 t', findRichText: true), findsOneWidget);
    expect(api.inventoryRequests.last['categoryId'], isNull);
    expect(api.inventoryRequests.last['keyword'], '新货品');
    expect(tester.widget<TextButton>(details).onPressed, isNotNull);
    expect(find.textContaining('统计暂不可用', findRichText: true), findsNothing);
    await tester.tap(details);
    await tester.pumpAndSettle();
    expect(router.state.uri.path, RouteName.stockInstantInventoryOverview);
    expect(router.state.uri.queryParameters['categoryId'], isNull);
    expect(router.state.uri.queryParameters['keyword'], '新货品');
    expect(tester.takeException(), isNull);
  });

  testWidgets('快速改词禁用旧导出打印，新结果完成后只导出当前关键词', (tester) async {
    final api = InstantInventoryApiFixture(
      withTotals: true,
      withAnalysis: true,
      withCategories: true,
    );
    await _pumpPage(
      tester,
      const Size(1500, 1000),
      api: api,
      permissions: const {Perm.stockReportExport},
    );
    final inventory = Completer<Map<String, dynamic>>();
    api.nextInventoryResponse = inventory.future;
    final search = find.descendant(
      of: find.byKey(const Key('instant-inventory-search')),
      matching: find.byType(EditableText),
    );
    UtenExportButton export() =>
        tester.widget<UtenExportButton>(find.byType(UtenExportButton));
    UtenPrintPreviewButton preview() => tester.widget<UtenPrintPreviewButton>(
      find.byType(UtenPrintPreviewButton),
    );
    expect(export().enabled, isTrue);
    await tester.enterText(search, '螺丝');
    await tester.pump(const Duration(milliseconds: 50));
    await tester.enterText(search, '螺丝 M3');
    await tester.pump(const Duration(milliseconds: 50));
    expect(export().enabled, isFalse);
    expect(preview().enabled, isFalse);
    for (final type in [
      find.byType(UtenExportButton),
      find.byType(UtenPrintPreviewButton),
    ]) {
      expect(
        tester
            .widget<UtenButton>(
              find.descendant(of: type, matching: find.byType(UtenButton)),
            )
            .onPressed,
        isNull,
      );
    }
    expect(
      api.inventoryRequests.where((request) => request['keyword'] == '螺丝'),
      isEmpty,
    );
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pump();
    expect(export().enabled, isFalse);
    expect(preview().enabled, isFalse);
    inventory.complete(api.response());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(export().enabled, isTrue);
    expect(preview().enabled, isTrue);
    expect(export().queryParams['keyword'], '螺丝 M3');
    expect(export().queryParams['categoryId'], isNull);
    expect(preview().exportQuery!['keyword'], '螺丝 M3');
    await preview().loader();
    expect(api.inventoryRequests.last['keyword'], '螺丝 M3');
    expect(api.inventoryRequests.last['categoryId'], isNull);
    expect(export().enabled, isTrue);
    expect(preview().enabled, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏 + 1.5× 字号：合计条和详情均不溢出', (tester) async {
    await _pumpPage(tester, const Size(375, 812), textScale: 1.5);

    expect(find.byType(InstantInventorySummaryBar), findsOneWidget);
    expect(find.text('查看详情'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.text('查看详情'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看详情'));
    await tester.pumpAndSettle();
    expect(find.text('库存总览与分析'), findsOneWidget);
    await tester.ensureVisible(find.text('按单位统计'));
    await tester.pumpAndSettle();
    expect(find.text('900'), findsOneWidget);
    expect(find.text('20'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<GoRouter> _pumpPage(
  WidgetTester tester,
  Size size, {
  bool withTotals = true,
  bool withAnalysis = true,
  double textScale = 1.0,
  InstantInventoryApiFixture? api,
  Set<String> permissions = const {},
  String? initialLocation,
  InstantInventoryScope? legacyInitialScope,
}) async {
  SharedPreferences.setMockInitialValues(const {});
  final prefs = await SharedPreferences.getInstance();

  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    initialLocation: initialLocation ?? RouteName.stockInstantInventory,
    routes: [
      GoRoute(
        path: RouteName.stockInstantInventory,
        builder: (_, state) => legacyInitialScope != null
            ? InstantInventoryPage(initialScope: legacyInitialScope)
            : state.uri.queryParameters.isEmpty
            ? const InstantInventoryPage()
            : InstantInventoryPage(
                initialNavigation: InstantInventoryNavigationContext.fromQuery(
                  state.uri.queryParameters,
                ),
              ),
      ),
      GoRoute(
        path: '${RouteName.stockItemBase}/:goodsId',
        builder: (_, _) => const Scaffold(body: Text('库存行详情')),
      ),
      GoRoute(
        path: '/inventory-origin',
        builder: (_, _) => const Scaffold(body: Text('库存业务来源')),
      ),
      GoRoute(
        path: '/stock/instant-inventory/overview',
        builder: (_, state) => InstantInventoryOverviewPage(
          scope: InstantInventoryScope.fromQuery(state.uri.queryParameters),
          scopeLabel: state.uri.queryParameters['scopeLabel'],
        ),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(
          api ??
              InstantInventoryApiFixture(
                withTotals: withTotals,
                withAnalysis: withAnalysis,
              ),
        ),
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

Future<void> _chooseCategory(WidgetTester tester, String label) async {
  final field = find.byKey(const Key('instant-inventory-category'));
  await tester.ensureVisible(field);
  await tester.pumpAndSettle();
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(
      of: find.byType(UtenCategoryTreeView<ProductCategoryNode>),
      matching: find.text(label),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('确定').last);
  await tester.pumpAndSettle();
}

const _upstreamReturnTo = '/inventory-origin?department=production&label=stock';

Finder _inventorySearch() => find.descendant(
  of: find.byKey(const Key('instant-inventory-search')),
  matching: find.byType(EditableText),
);

void _expectNavigationScope(
  Map<String, dynamic> query, {
  required String? category,
  required String? keyword,
}) {
  expect(query['categoryId'], category);
  expect(query['keyword'], keyword);
  expect(query['includeRelated'], keyword == null ? null : isTrue);
  expect(query['warehouseId'], 'warehouse-main');
  expect(query['includeDefective'], isTrue);
  expect(query['includeLineSide'], isTrue);
  expect(query['owningWarehouse'], 'warehouse-owner');
  expect(query['colorId'], 'red');
  expect(query['series'], 'GD');
  expect(query['unitId'], 'unit-1');
  expect(query, isNot(contains('browseCategoryId')));
  expect(query, isNot(contains('returnTo')));
}

class _NavigationApiFixture extends InstantInventoryApiFixture {
  _NavigationApiFixture() : super(withTotals: true, withAnalysis: true);

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => path.contains('material-categories/tree')
      ? [
          {'id': 'raw', 'code': 'RAW', 'name': '原材料', 'goodsCount': 137},
          {'id': 'finished', 'code': 'FIN', 'name': '成品', 'goodsCount': 2},
        ]
      : super.getList(path, query: query);

  @override
  Future<List<String>> getStringList(
    String path, {
    Map<String, dynamic>? query,
  }) async => ['raw', 'finished'];
}
