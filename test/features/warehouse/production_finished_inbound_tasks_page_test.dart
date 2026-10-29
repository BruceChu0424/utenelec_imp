// 产成品入库队列(2026-10-17 起 /warehouse/production-finished-inbound 深链直落
// 「入库任务中心 · 产成品入库」分段): 待登记与最终点收两族任务在同一多选表;
// ADR-184 起「先入库后质检」资格由服务端折进行事实 canRegisterBeforeInspection,
// 触发批量动作时仍观察当前资格(只读身份 / 行资格被服务端撤回)。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_task_center_record.dart';
import 'package:uten_imp/features/warehouse/pages/production_finished_inbound_tasks_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/warehouse/warehouse_task_badges.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../helpers/warehouse_request_scope_fixture.dart';

const _reportId = '20000000-0000-0000-0000-000000000001';
const _documentId = '10000000-0000-0000-0000-000000000001';
const _registerRowKey = 'FINISHED:FINISHED_REGISTER:$_reportId';
const _countRowKey = 'FINISHED:FINAL_COUNT:$_documentId';
final _liveTaskPermissions = StateProvider<Set<String>>(
  (ref) => const {
    Perm.stockDocView,
    Perm.stockDocApprove,
    Perm.productionFinishedInBeforeInspection,
  },
);
final _liveTaskScope = StateProvider<AuthenticatedScope?>(
  (ref) => const AuthenticatedScope(userId: 'warehouse-user'),
);

void main() {
  for (final mode in ['readOnly', 'serverWithdraws']) {
    testWidgets(
      'finished queue stale shelf action observes current authority ($mode)',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1400, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        var navigations = 0;
        final api = _FinishedInboundApi();
        final router = GoRouter(
          initialLocation: '/',
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => const ProductionFinishedInboundTasksPage(),
            ),
            GoRoute(
              path: RouteName.warehouseProductionFinishedArrivalRegistration,
              builder: (_, _) {
                navigations++;
                return const Scaffold(body: Text('finished shelf'));
              },
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              ...warehouseRequestScopeFixture(
                includeClient: false,
                includeIdentity: false,
                includeBadges: false,
                authenticatedSession: true,
              ),
              apiClientProvider.overrideWithValue(api),
              sharedPreferencesProvider.overrideWithValue(preferences),
              isSuperAdminProvider.overrideWithValue(true),
              currentPermissionsProvider.overrideWith(
                (ref) => ref.watch(_liveTaskPermissions),
              ),
              authenticatedScopeProvider.overrideWith(
                (ref) => ref.watch(_liveTaskScope),
              ),
              fixedBadgeSummaryOverride(
                badgeSummaryFixture(
                  facts: const {BadgeFact.finishedInbound: 1},
                ),
              ),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await tester.pumpAndSettle();
        _table(tester).onSelectedIdsChanged!(const {_registerRowKey});
        await tester.pump();
        final stale = tester
            .widget<UtenButton>(
              find.ancestor(
                of: find.text('批量登记（先入库后质检）'),
                matching: find.byType(UtenButton),
              ),
            )
            .onPressed;
        expect(stale, isNotNull);
        if (mode == 'readOnly') {
          final container = ProviderScope.containerOf(
            tester.element(find.text('批量登记（先质检后入库）')),
          );
          container
              .read(_liveTaskScope.notifier)
              .state = const AuthenticatedScope(
            userId: 'finished-reader',
            actorId: 'actor',
            readOnly: true,
          );
          await tester.pump();
        } else {
          // ADR-184：动作资格折进行事实 —— 服务端刷新后撤回「先入库后质检」,
          // 行资格与选择集一起失效。
          api.allowPreStock = false;
          await tester.tap(find.byTooltip('刷新'));
          await tester.pumpAndSettle();
          expect(find.text('批量登记（先入库后质检）'), findsNothing);
        }
        stale!();
        await tester.pumpAndSettle();
        expect(navigations, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final withExtra in [false, true]) {
    testWidgets(
      'sparse superadmin finished queue requires explicit extra ($withExtra)',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1400, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final api = _FinishedInboundApi()..allowPreStock = withExtra;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              ...warehouseRequestScopeFixture(
                includeClient: false,
                includeIdentity: false,
                includeBadges: false,
                authenticatedSession: true,
              ),
              apiClientProvider.overrideWithValue(api),
              sharedPreferencesProvider.overrideWithValue(preferences),
              isSuperAdminProvider.overrideWithValue(true),
              currentPermissionsProvider.overrideWithValue({
                Perm.stockDocView,
                Perm.stockDocApprove,
                if (withExtra) Perm.productionFinishedInBeforeInspection,
              }),
              fixedBadgeSummaryOverride(
                badgeSummaryFixture(
                  facts: const {BadgeFact.finishedInbound: 1},
                ),
              ),
            ],
            child: const MaterialApp(
              home: ProductionFinishedInboundTasksPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        _table(tester).onSelectedIdsChanged!(const {_registerRowKey});
        await tester.pump();
        // ADR-184：超管不再隐式获得「先入库后质检」——服务端只按显式权限
        // 折进行事实, 没有额外权限时只保留「先质检后入库」。
        expect(
          find.text('批量登记（先入库后质检）'),
          withExtra ? findsOneWidget : findsNothing,
        );
        expect(find.text('批量登记（先质检后入库）'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('finished inbound queue uses the multi-select table at 375px', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();

    final api = _FinishedInboundApi()..allowPreStock = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...warehouseRequestScopeFixture(
            includeClient: false,
            includeIdentity: false,
            includeBadges: false,
            authenticatedSession: true,
          ),
          apiClientProvider.overrideWithValue(api),
          sharedPreferencesProvider.overrideWithValue(preferences),
          isSuperAdminProvider.overrideWithValue(false),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.stockDocView,
            Perm.stockDocApprove,
          }),
          fixedBadgeSummaryOverride(
            badgeSummaryFixture(facts: const {BadgeFact.finishedInbound: 2}),
          ),
        ],
        child: const MaterialApp(home: ProductionFinishedInboundTasksPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('产成品入库'), findsOneWidget);
    expect(find.text('共 2 条'), findsOneWidget);
    expect(find.text('待登记入库'), findsOneWidget);
    expect(find.text('短收余量待点收'), findsOneWidget);
    expect(find.text('SJ202608280001'), findsOneWidget);
    var table = _table(tester);
    expect(table.selectable, isTrue);
    expect(table.batchActionsBuilder, isNotNull);
    expect(table.columns.map((column) => column.label), [
      '状态',
      '单据 / 任务单号',
      '货品名称',
      '货品编码',
      '颜色',
      '规格',
      '数量',
      '来源单据',
      '客户 / 供应商 / 委外商',
      '仓库',
      '业务日期',
      '负责人',
      '制单人',
    ]);
    final actionLabels = [
      for (final item in table.items)
        (table.rowMenuBuilder!(item).single as UtenMenuItem).label,
    ];
    expect(actionLabels, ['打开办理', '打开办理']);

    await tester.tap(find.text('待登记入库'));
    await tester.pump();
    table = _table(tester);
    // 登记任务按来源行键选中; 没有「先入库后质检」独立资格时只显示
    // 「先质检后入库(N)」。
    expect(table.idOf!(table.items.first), _registerRowKey);
    expect(find.byKey(const Key('warehouse-task-record-batch')), findsNothing);
    expect(find.text('批量登记（先质检后入库）'), findsOneWidget);
    expect(find.text('批量登记（先入库后质检）'), findsNothing);
    expect(table.selectedIds, {_registerRowKey});
    await tester.tap(find.text('短收余量待点收'));
    await tester.pump();
    table = _table(tester);
    expect(table.idOf!(table.items.last), _countRowKey);
    expect(table.selectedIds, {_registerRowKey, _countRowKey});
    // 登记送检与最终点收属不同办理族：混选没有统一动作(按钮禁用，只给分别选择提示)。
    final mixed = find.text('批量办理');
    expect(mixed, findsOneWidget);
    final mixedButton = tester.widget<UtenButton>(
      find.ancestor(of: mixed, matching: find.byType(UtenButton)),
    );
    expect(mixedButton.onPressed, isNull);
    expect(mixedButton.onDisabledTap, isNotNull);
    await tester.tap(find.text('待登记入库'));
    await tester.pump();
    table = _table(tester);
    expect(table.selectedIds, {_countRowKey});
    // 只剩最终点收任务 → 核对最终点收进入批量点收页 → 小结确认 → 整批提交。
    final batchButton = find.byKey(const Key('warehouse-task-record-batch'));
    expect(batchButton, findsOneWidget);
    expect(find.text('批量点收'), findsOneWidget);
    await tester.ensureVisible(batchButton);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(batchButton);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('production-finished-batch-stock-in-table')),
      findsOneWidget,
    );
    expect(find.text('已选 1 项'), findsOneWidget, reason: '批量页只保留右下唯一选择摘要');
    await tester.tap(
      find.byKey(const Key('production-finished-batch-confirm')),
    );
    await tester.pumpAndSettle();
    expect(find.text('确认所选点收（1 张）'), findsOneWidget);
    await tester.tap(find.text('确认批量入库'));
    await tester.pumpAndSettle();

    expect(api.batchBody?['documentIds'], [_documentId]);
    expect(api.batchBody?['idempotencyKey'], startsWith('finished-in-batch-'));
    expect(find.text('短收余量待点收'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('finished inbound queue gives view-only staff no count promise', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...warehouseRequestScopeFixture(
            includeClient: false,
            includeIdentity: false,
            includeBadges: false,
            authenticatedSession: true,
          ),
          apiClientProvider.overrideWithValue(
            _FinishedInboundApi()..rowsHandleable = false,
          ),
          sharedPreferencesProvider.overrideWithValue(preferences),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.stockDocView,
          }),
          isSuperAdminProvider.overrideWithValue(false),
          // ADR-184：只读查看不计任务红数 —— 汇总不带回 finishedInbound 事实。
          fixedBadgeSummaryOverride(badgeSummaryFixture()),
        ],
        child: const MaterialApp(home: ProductionFinishedInboundTasksPage()),
      ),
    );
    await tester.pumpAndSettle();

    final table = _table(tester);
    final actionLabels = [
      for (final item in table.items)
        (table.rowMenuBuilder!(item).single as UtenMenuItem).label,
    ];
    expect(actionLabels, ['查看原单', '查看原单']);
    expect(table.selectable, isFalse);
    expect(table.batchActionsBuilder, isNull);
    final container = ProviderScope.containerOf(
      tester.element(find.text('产成品入库')),
    );
    expect(
      container.read(
        warehouseTaskFactOrNullProvider(BadgeFact.finishedInbound),
      ),
      isNull,
      reason: '汇总未带回该事实时分段不显示任何数(不把未知伪装成 0)',
    );
    expect(tester.takeException(), isNull);
  });
}

MasterDataTableView<WarehouseTaskCenterRecord> _table(WidgetTester tester) =>
    tester.widget(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<WarehouseTaskCenterRecord>,
      ),
    );

class _FinishedInboundApi extends ApiClient {
  _FinishedInboundApi() : super(Dio());

  Map<String, dynamic>? batchBody;
  bool batchConfirmed = false;

  /// 服务端按显式权限折进行事实的「先入库后质检」资格(ADR-184)。
  bool allowPreStock = true;

  /// 服务端下发的行办理资格; false 模拟只读账号。
  bool rowsHandleable = true;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/warehouse/task-center/inbound') {
      return {
        'items': [
          {
            'rowKey': _registerRowKey,
            'id': _reportId,
            'sourceType': 'FINISHED',
            'recordType': 'FINISHED_ARRIVAL_REPORT',
            'status': 'FINISHED_REGISTER',
            'statusLabel': '待登记入库',
            'billNo': 'SJ202608280001',
            'businessDate': '2026-08-28',
            'warehouseName': '半成品仓',
            'action': 'FINISHED_REGISTER',
            'targetId': _reportId,
            'canHandle': rowsHandleable,
            'actionData': {
              'reportId': _reportId,
              'canRegisterBeforeInspection': allowPreStock,
            },
          },
          if (!batchConfirmed)
            {
              'rowKey': _countRowKey,
              'id': _documentId,
              'sourceType': 'FINISHED',
              'recordType': 'FINISHED_IN_DOCUMENT',
              'status': 'FINAL_COUNT',
              'statusLabel': '短收余量待点收',
              'billNo': 'CPRK202608280001',
              'businessDate': '2026-08-28',
              'warehouseName': '半成品仓',
              'action': 'FINISHED_COUNT',
              'targetId': _documentId,
              'canHandle': rowsHandleable,
              'actionData': {
                'taskId': _documentId,
                'documentId': _documentId,
                'pendingQty': 1000,
              },
            },
        ],
        'page': 1,
        'size': 40,
        'total': batchConfirmed ? 1 : 2,
        'totalPages': 1,
        'facets': const <String, dynamic>{},
      };
    }
    return const {'items': <Map<String, dynamic>>[], 'page': 1, 'total': 0};
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    expect(path, ApiEndpoints.productionFinishedInboundBatchConfirm);
    batchBody = Map<String, dynamic>.from(body! as Map<String, dynamic>);
    batchConfirmed = true;
    return {
      'batchId': 'batch-1',
      'replay': false,
      'confirmedCount': 1,
      'items': [
        {'documentId': _documentId, 'billNo': 'CPRK202608280001', 'status': 1},
      ],
    };
  }
}
