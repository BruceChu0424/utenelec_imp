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

  testWidgets('详情为独立路由，返回保留原分类、搜索和表头筛选', (tester) async {
    final api = InstantInventoryApiFixture(
      withTotals: true,
      withAnalysis: true,
      withCategories: true,
    );
    final router = await _pumpPage(tester, const Size(1500, 1000), api: api);
    await tester.tap(_categoryText('原材料'));
    await tester.pumpAndSettle();
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
    expect(_categoryText('原材料'), findsOneWidget);
    expect(tester.widget<EditableText>(search).controller.text, '原材料');
    expect(
      tester
          .widget<MasterDataTableView<InstantInventoryRow>>(tableFinder)
          .filters,
      {'series': 'GD'},
    );
    expect(find.byType(InstantInventorySummaryBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('行详情returnTo回放重建后搜索仍全局，清空恢复进入搜索前的分类', (tester) async {
    final api = InstantInventoryApiFixture(
      withTotals: true,
      withAnalysis: true,
      withCategories: true,
    );
    final router = await _pumpPage(tester, const Size(1500, 1000), api: api);
    await tester.tap(_categoryText('原材料'));
    await tester.pumpAndSettle();
    final search = find.descendant(
      of: find.byKey(const Key('instant-inventory-search')),
      matching: find.byType(EditableText),
    );
    await tester.enterText(search, '螺丝');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    final table = tester.widget<MasterDataTableView<InstantInventoryRow>>(
      find.byType(MasterDataTableView<InstantInventoryRow>),
    );
    table.onFilterChanged('series', 'GD');
    await tester.pumpAndSettle();
    final oldState = tester.state(find.byType(InstantInventoryPage));
    table.onRowTap!(table.items.first);
    await tester.pumpAndSettle();
    expect(router.state.uri.path, startsWith(RouteName.stockItemBase));
    final returnTo = router.state.uri.queryParameters['returnTo']!;
    final restoredUri = Uri.parse(returnTo);
    expect(
      restoredUri.queryParameters['categoryId'],
      'raw',
      reason: '返回地址保存浏览恢复点，不是当前全局API范围',
    );
    expect(restoredUri.queryParameters['keyword'], '螺丝');
    expect(restoredUri.queryParameters['series'], 'GD');
    // Force a real reconstruction as a refresh/direct returnTo would do.
    router.go('${RouteName.stockItemBase}/replay');
    await tester.pumpAndSettle();
    router.go(returnTo);
    await tester.pumpAndSettle();
    expect(
      tester.state(find.byType(InstantInventoryPage)),
      isNot(same(oldState)),
    );
    expect(api.inventoryRequests.last['categoryId'], isNull);
    expect(api.inventoryRequests.last['keyword'], '螺丝');
    expect(api.inventoryRequests.last['series'], 'GD');
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('instant-inventory-search')),
        matching: find.byIcon(Icons.close_rounded),
      ),
    );
    await tester.pumpAndSettle();
    expect(api.inventoryRequests.last['categoryId'], 'raw');
    expect(api.inventoryRequests.last['keyword'], isNull);
    expect(api.inventoryRequests.last['series'], 'GD');
    expect(tester.takeException(), isNull);
  });

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

  testWidgets('防抖和结果更新期间禁旧合计，分类提示延迟或失败不挡当前全局汇总', (tester) async {
    final api = InstantInventoryApiFixture(
      withTotals: true,
      withAnalysis: true,
      withCategories: true,
    );
    final router = await _pumpPage(tester, const Size(1500, 1000), api: api);
    final inventory = Completer<Map<String, dynamic>>();
    api.nextInventoryResponse = inventory.future;
    final request = Completer<List<String>>();
    api.nextSearchResponse = request.future;
    final search = find.descendant(
      of: find.byKey(const Key('instant-inventory-search')),
      matching: find.byType(EditableText),
    );
    final details = find.byKey(const Key('instant-inventory-summary-details'));

    await tester.enterText(search, '新货品');
    await tester.pump();
    expect(tester.widget<TextButton>(details).onPressed, isNull);
    expect(find.textContaining('3.52 t', findRichText: true), findsNothing);

    await tester.pump(const Duration(milliseconds: 301));
    expect(tester.widget<TextButton>(details).onPressed, isNull);
    expect(find.textContaining('统计更新中…', findRichText: true), findsOneWidget);

    inventory.complete(api.response());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester.widget<TextButton>(details).onPressed,
      isNotNull,
      reason: '真实全局结果已更新，树提示仍在请求中也可查看同口径汇总',
    );
    expect(find.textContaining('3.52 t', findRichText: true), findsOneWidget);
    expect(api.inventoryRequests.last['categoryId'], isNull);
    expect(api.inventoryRequests.last['keyword'], '新货品');
    request.completeError(StateError('分类定位失败'));
    await tester.pumpAndSettle();
    expect(find.text('重试搜索'), findsOneWidget);
    expect(tester.widget<TextButton>(details).onPressed, isNotNull);
    expect(find.textContaining('统计暂不可用', findRichText: true), findsNothing);
    await tester.tap(details);
    await tester.pumpAndSettle();
    expect(router.state.uri.path, RouteName.stockInstantInventoryOverview);
    expect(router.state.uri.queryParameters['categoryId'], isNull);
    expect(router.state.uri.queryParameters['keyword'], '新货品');
    expect(tester.takeException(), isNull);
  });

  testWidgets('快速改词禁用旧导出打印，新结果已更新即使分类提示未完成仍能导出新词', (tester) async {
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
    final locator = Completer<List<String>>();
    final inventory = Completer<Map<String, dynamic>>();
    api.nextSearchResponse = locator.future;
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
    locator.completeError(StateError('分类提示失败'));
    await tester.pumpAndSettle();
    expect(find.text('重试搜索'), findsOneWidget);
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
}) async {
  SharedPreferences.setMockInitialValues(const {});
  final prefs = await SharedPreferences.getInstance();

  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    initialLocation: RouteName.stockInstantInventory,
    routes: [
      GoRoute(
        path: RouteName.stockInstantInventory,
        builder: (_, state) => state.uri.queryParameters.isEmpty
            ? const InstantInventoryPage()
            : InstantInventoryPage(
                initialScope: InstantInventoryScope.fromQuery(
                  state.uri.queryParameters,
                ),
              ),
      ),
      GoRoute(
        path: '${RouteName.stockItemBase}/:goodsId',
        builder: (_, _) => const Scaffold(body: Text('库存行详情')),
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

Finder _categoryText(String label) => find.descendant(
  of: find.byType(UtenCategoryTreeView<ProductCategoryNode>),
  matching: find.text(label),
);
