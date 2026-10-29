// 委外出库分段(2026-10-17 起 /warehouse/subcontract-outbound 深链直落
// 「出库任务中心 · 委外出库」分段): 一行 = 一张委外人员已提交、仓库未发出的
// 领料单; 单击选中、双击打开(有本机填写快照先按同一领料 UUID 续填);
// ADR-184 起勾选批量核对出库的动作权由服务端逐行 canHandle 下发。
import '../../support/table_read_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_task_center_record.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_subcontract_outbound_batch_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_subcontract_outbound_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/drafts/form_draft_catalog.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

import '../../helpers/badge_summary_fixture.dart';
import 'outbound_weight_fakes.dart';
import 'subcontract_outbound_test_support.dart';

late SharedPreferences _preferences;

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });

  for (final unknown in [false, true]) {
    testWidgets('原待发料行显示填写状态且按同一领料UUID续填，待核对=$unknown', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = SubcontractOutboundFakeApi();
      final router = _router();
      addTearDown(router.dispose);
      final spec = FormDraftCatalog.subcontractOutbound.spec(
        route: '/warehouse/subcontract-outbound/issue-1',
      );
      final draft = FormDraft(
        id: 'original-input',
        title: '原拣货填写',
        module: spec.module,
        route: spec.route,
        permission: spec.permission,
        data: {formDraftUnknownSubmissionKey: unknown},
        updatedAt: DateTime.utc(2026, 10, 11),
      );
      await tester.pumpWidget(
        _app(
          api: api,
          router: router,
          permissions: subcontractOutboundPermissions,
          drafts: [draft],
        ),
      );
      await tester.pumpAndSettle();
      final table = _table(tester);
      expect(table.items, hasLength(3));
      final status = table.columns.singleWhere(
        (column) => column.key == 'status',
      );
      // 有填写快照的行状态切换成「来源 · 草稿/提交待核对」，其余照常待发料。
      expect(
        status.value(table.items.first),
        '委外出库 · ${unknown ? '提交待核对' : '草稿'}',
      );
      expect(status.value(table.items[1]), '委外出库 · 待发料');
      table.onRowTap!(table.items.first);
      await tester.pumpAndSettle();
      expect(find.text('detail-issue-1'), findsOneWidget);
      final opened = GoRouterState.of(
        tester.element(find.text('detail-issue-1')),
      ).uri;
      expect(opened.path, '/warehouse/subcontract-outbound/issue-1');
      expect(opened.queryParameters['draftId'], 'original-input');
      expect(api.updates, isEmpty);
      expect(api.approvals, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('服务端办结离开待发料队列后，未知原提交仍有核对入口', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = SubcontractOutboundFakeApi()..taskHeaders.clear();
    final router = _router();
    addTearDown(router.dispose);
    final spec = FormDraftCatalog.subcontractOutbound.spec(
      route: '/warehouse/subcontract-outbound/issue-1',
    );
    final draft = FormDraft(
      id: 'unknown-original',
      title: '原提交核对',
      module: spec.module,
      route: spec.route,
      permission: spec.permission,
      data: const {formDraftUnknownSubmissionKey: true},
      updatedAt: DateTime.utc(2026, 10, 11),
    );
    await tester.pumpWidget(
      _app(
        api: api,
        router: router,
        permissions: subcontractOutboundPermissions,
        drafts: [draft],
      ),
    );
    await tester.pumpAndSettle();
    expect(_table(tester).items, isEmpty);
    expect(find.text('核对原提交'), findsOneWidget);
    await tester.tap(find.text('核对原提交'));
    await tester.pumpAndSettle();
    expect(find.text('detail-issue-1'), findsOneWidget);
    final opened = GoRouterState.of(
      tester.element(find.text('detail-issue-1')),
    ).uri;
    expect(opened.queryParameters['draftId'], 'unknown-original');
    expect(api.updates, isEmpty);
    expect(api.approvals, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('一行一张领料单: 单击选中、双击按领料单进拣货页, 返回后重拉列表', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // ADR-184：没有出仓执行资格的账号由服务端在行上下发 canHandle=false，
    // 行仍可见可看原单，但前端不给勾选批量办理。
    final api = SubcontractOutboundFakeApi()..rowsHandleable = false;
    final router = _router();
    addTearDown(router.dispose);

    await tester.pumpWidget(_app(api: api, router: router));
    await tester.pumpAndSettle();

    final table = _table(tester);
    expect(table.selectable, isFalse, reason: '服务端未授予办理资格不给勾选');
    expect(table.batchActionsBuilder, isNull);
    expect(table.facets['status'], isEmpty, reason: '列表只有待发料一种状态');
    expect(table.columns.map((column) => column.label), [
      '状态',
      '单据 / 任务单号',
      '货品名称',
      '货品编码',
      '颜色',
      '规格',
      '数量',
      '来源单据',
      '生产工单',
      '客户 / 供应商 / 委外商',
      '仓库',
      '业务日期',
      '负责人',
      '制单人',
    ]);
    final labels = table.columns.map((column) => column.label);
    for (final retired in const ['任务状态', '目标件行数', '出仓草稿单', '等子件到货']) {
      expect(labels, isNot(contains(retired)));
    }
    expect(table.items.map((row) => row.targetId), [
      'issue-1',
      'issue-2',
      'issue-3',
    ]);
    final query = api.taskQueries.first;
    expect(query['source'], 'SUBCONTRACT');
    expect(query.containsKey('status'), isFalse);
    expect(query.containsKey('supplierId'), isFalse);
    final menu = table.rowMenuBuilder!(table.items.first);
    expect((menu.single as UtenMenuItem).label, '查看原单');
    expect(find.text('共 3 条'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);

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
    expect(find.text('仓库任务中心'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('服务端授予办理资格时可勾选多张领料单进批量出库页', (tester) async {
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
    expect(
      table.idOf!(table.items.first),
      'SUBCONTRACT:SUBCONTRACT_MATERIAL_ISSUE:issue-1',
    );
    table.onSelectedIdsChanged!({
      'SUBCONTRACT:SUBCONTRACT_MATERIAL_ISSUE:issue-1',
      'SUBCONTRACT:SUBCONTRACT_MATERIAL_ISSUE:issue-3',
    });
    await tester.pump();
    await tester.tap(find.byKey(const Key('warehouse-task-record-batch')));
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

    expect(_table(tester), isNotNull);
    expect(tester.takeException(), isNull);

    final searchField = find.descendant(
      of: find.byKey(const Key('warehouse-task-center-search')),
      matching: find.byType(TextField),
    );
    await tester.enterText(searchField, 'missing');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(api.taskQueries.last['keyword'], 'missing');
    expect(find.text('当前范围与筛选下没有单据'), findsOneWidget);

    await tester.enterText(searchField, '');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    _table(tester).onPageChange!(2);
    await tester.pumpAndSettle();
    expect(api.taskQueries.last['page'], 2);

    api.failNextList = true;
    final listRequests = api.listRequests;
    final refresh = find.byTooltip('刷新').hitTestable();
    if (refresh.evaluate().isNotEmpty) {
      await tester.tap(refresh);
    } else {
      // 窄屏下刷新可能收进应用栏更多菜单。
      final moreActions = find
          .byKey(const Key('uten-app-bar-more-actions'))
          .hitTestable();
      expect(moreActions, findsOneWidget);
      await tester.tap(moreActions);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('刷新').hitTestable());
    }
    await tester.pumpAndSettle();
    expect(api.listRequests, listRequests + 1);
    await expectTableReadFailureDetails(tester, '仓库单据加载失败，请重试');
    expect(tester.takeException(), isNull);
  });
}

Widget _app({
  required SubcontractOutboundFakeApi api,
  required GoRouter router,
  Set<String> permissions = const {Perm.subcontractOutboundView},
  List<FormDraft>? drafts,
}) {
  return ProviderScope(
    overrides: [
      if (drafts != null)
        formDraftsProvider.overrideWith(() => _Drafts(drafts)),
      if (drafts != null)
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'warehouse-user'),
        ),
      if (drafts != null)
        apiBaseUrlProvider.overrideWithValue('https://task-ui.example/api'),
      fakeWeightRepositoryOverride(),
      apiClientProvider.overrideWithValue(api),
      masterNameServiceProvider.overrideWithValue(OutboundNames(api)),
      currentPermissionsProvider.overrideWithValue(permissions),
      isSuperAdminProvider.overrideWithValue(false),
      sharedPreferencesProvider.overrideWithValue(_preferences),
      // ADR-184：分段红数与资格事实改由徽章汇总提供; 固定汇总避免真实轮询。
      fixedBadgeSummaryOverride(
        badgeSummaryFixture(facts: const {BadgeFact.subcontractOutbound: 3}),
      ),
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
        path: '/warehouse/subcontract-outbound/batch',
        builder: (context, state) => WarehouseSubcontractOutboundBatchPage(
          issueIds: state.uri.queryParameters['issueIds']!.split(','),
        ),
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

class _Drafts extends FormDraftsNotifier {
  _Drafts(this.values);
  final List<FormDraft> values;
  @override
  List<FormDraft> build() => values;
}

MasterDataTableView<WarehouseTaskCenterRecord> _table(WidgetTester tester) {
  return tester.widget<MasterDataTableView<WarehouseTaskCenterRecord>>(
    find.byWidgetPredicate(
      (widget) => widget is MasterDataTableView<WarehouseTaskCenterRecord>,
    ),
  );
}

Future<void> _doubleTapRow(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 40));
  await tester.tap(finder);
}
