// 委外出仓工作台列表(ADR-143 §4.3): 一行 = 一张委外人员已提交、仓库未发出的
// 领料单; 单击选中、双击按领料单 id 进拣货页; 有执行权限才可勾选批量出库。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/models/subcontract_outbound.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_subcontract_outbound_batch_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_subcontract_outbound_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import 'outbound_weight_fakes.dart';
import 'subcontract_outbound_test_support.dart';

late SharedPreferences _preferences;

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });

  testWidgets('一行一张领料单: 单击选中、双击按领料单进拣货页, 返回后重拉列表', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = SubcontractOutboundFakeApi();
    final router = _router();
    addTearDown(router.dispose);

    await tester.pumpWidget(_app(api: api, router: router));
    await tester.pumpAndSettle();

    final table = _table(tester);
    expect(table.selectable, isFalse, reason: '没有出仓执行权限不给勾选');
    expect(table.batchActionsBuilder, isNull);
    expect(table.facets, isEmpty, reason: '列表只有待发料一种状态');
    expect(table.columns.map((column) => column.label), [
      '领料单号',
      '委外订货单',
      '委外商',
      '领料仓',
      '物料种数',
      '明细行数',
      '提交时间',
      '提交人',
    ]);
    final labels = table.columns.map((column) => column.label);
    for (final retired in const ['任务状态', '目标件行数', '出仓草稿单', '等子件到货']) {
      expect(labels, isNot(contains(retired)));
    }
    expect(table.items.map((task) => task.issueId), [
      'issue-1',
      'issue-2',
      'issue-3',
    ]);
    final query = api.taskQueries.first;
    expect(query.containsKey('status'), isFalse);
    expect(query.containsKey('supplierId'), isFalse);
    final menu = table.rowMenuBuilder!(table.items.first);
    expect((menu.single as UtenMenuItem).label, '进入拣货出仓');
    expect(find.text('共 3 项 · 单击选中，双击详情'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
    expect(find.textContaining('数量只能改少不能改多'), findsOneWidget);

    await tester.tap(find.text('EC-1'));
    await tester.pump();
    expect(
      router.routeInformationProvider.value.uri.path,
      RouteName.warehouseSubcontractOutbound,
    );

    await tester.pump(const Duration(milliseconds: 400));
    await _doubleTapRow(tester, find.text('EC-1'));
    await tester.pumpAndSettle();
    expect(find.text('detail-issue-1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('complete-outbound-task')));
    await tester.pumpAndSettle();
    expect(api.listRequests, 2);
    expect(find.text('委外出仓任务中心'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('有出仓执行权限时可勾选多张领料单进批量出库页', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = SubcontractOutboundFakeApi();
    final router = _router();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      _app(
        api: api,
        router: router,
        permissions: subcontractOutboundPermissions,
      ),
    );
    await tester.pumpAndSettle();

    final table = _table(tester);
    expect(table.selectable, isTrue);
    expect(table.idOf!(table.items.first), 'issue-1');
    table.onSelectedIdsChanged!({'issue-1', 'issue-3'});
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('subcontract-outbound-batch-action')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(WarehouseSubcontractOutboundBatchPage), findsOneWidget);
    expect(api.taskReads.toSet(), {'issue-1', 'issue-3'});
    expect(api.updates, isEmpty, reason: '打开批量页只读不写');
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏仍是表格, 搜索 / 翻页 / 加载失败照常', (tester) async {
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = SubcontractOutboundFakeApi();
    final router = _router();
    addTearDown(router.dispose);

    await tester.pumpWidget(_app(api: api, router: router));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('subcontract-outbound-task-table')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    final searchField = find.descendant(
      of: find.byKey(const Key('subcontract-outbound-search')),
      matching: find.byType(TextField),
    );
    await tester.enterText(searchField, 'missing');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(api.taskQueries.last['keyword'], 'missing');
    expect(find.text('没有匹配「missing」的委外领料单'), findsOneWidget);

    await tester.enterText(searchField, '');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    _table(tester).onPageChange!(2);
    await tester.pumpAndSettle();
    expect(api.taskQueries.last['page'], 2);

    api.failNextList = true;
    await tester.tap(find.text('刷新'));
    await tester.pumpAndSettle();
    expect(find.text('委外领料单加载失败，请检查网络后重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Widget _app({
  required SubcontractOutboundFakeApi api,
  required GoRouter router,
  Set<String> permissions = const {Perm.subcontractOutboundView},
}) {
  return ProviderScope(
    overrides: [
      fakeWeightRepositoryOverride(),
      apiClientProvider.overrideWithValue(api),
      masterNameServiceProvider.overrideWithValue(OutboundNames(api)),
      currentPermissionsProvider.overrideWithValue(permissions),
      isSuperAdminProvider.overrideWithValue(false),
      sharedPreferencesProvider.overrideWithValue(_preferences),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

GoRouter _router() {
  return GoRouter(
    initialLocation: RouteName.warehouseSubcontractOutbound,
    routes: [
      GoRoute(
        path: RouteName.warehouseSubcontractOutbound,
        builder: (_, _) => const WarehouseSubcontractOutboundPage(),
      ),
      GoRoute(
        path: '/warehouse/subcontract-outbound/:issueId',
        builder: (context, state) => Scaffold(
          body: Column(
            children: [
              Text('detail-${state.pathParameters['issueId']}'),
              FilledButton(
                key: const Key('complete-outbound-task'),
                onPressed: () => context.pop(true),
                child: const Text('完成'),
              ),
            ],
          ),
        ),
      ),
    ],
  );
}

MasterDataTableView<OutboundTask> _table(WidgetTester tester) {
  return tester.widget<MasterDataTableView<OutboundTask>>(
    find.byWidgetPredicate(
      (widget) => widget is MasterDataTableView<OutboundTask>,
    ),
  );
}

Future<void> _doubleTapRow(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 40));
  await tester.tap(finder);
}
