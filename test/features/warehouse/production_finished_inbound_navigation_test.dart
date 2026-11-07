// 产成品入库导航(2026-10-17 起 /warehouse/production-finished-in/tasks 深链直落
// 「入库任务中心 · 产成品入库」分段): 列表/搜索/返回刷新走统一任务中心;
// 双击按任务阶段进现有到货登记路由, 保留 returnTo 与返回后的刷新;
// 多选两颗路线按钮的 preStock 参数由服务端行事实 + 所选路线决定(ADR-184)。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/core/network/server_selection.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_app_bar_action_button.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/buttons/uten_refresh_button.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/nav_helpers.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_task_center_record.dart';
import 'package:uten_imp/features/warehouse/pages/production_finished_inbound_tasks_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../helpers/warehouse_request_scope_fixture.dart';
import '../../support/uten_test_actions.dart';

const _arrivalTaskId = '20000000-0000-0000-0000-000000000001';
const _finalTaskId = '10000000-0000-0000-0000-000000000001';
const _registerRowKey = 'FINISHED:FINISHED_REGISTER:$_arrivalTaskId';
const _finalRowKey = 'FINISHED:FINAL_COUNT:$_finalTaskId';

late SharedPreferences _preferences;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });
  testWidgets(
    'hub entry loads once and refresh search arrival return stay operable',
    (tester) async {
      await setUtenTestSurfaceSize(tester, const Size(1200, 900));
      addTearDown(() => setUtenTestSurfaceSize(tester, null));
      final api = _TrackingFinishedInboundApi();
      final router = _buildRouter(initialLocation: RouteName.warehouse);
      addTearDown(router.dispose);

      await tester.pumpWidget(_testApp(api: api, router: router));
      await tester.pumpAndSettle();
      // 每个 MaterialRoute 都有一个透明、位于页面内容下方的 ModalBarrier。
      // 本用例防的是任务页新增遮罩，而不是误判框架自带的底层 barrier。
      final baselineModalBarrierCount = find
          .byType(ModalBarrier)
          .evaluate()
          .length;
      await tester.tap(find.byKey(const Key('open-finished-inbound-tasks')));
      await tester.pumpAndSettle();

      expect(api.taskRequestCount, 1);
      expect(
        api.preparationQueries,
        isEmpty,
        reason:
            'The complete current FINISHED scope does not speculate other business sources.',
      );
      // ADR-184：分段红数来自徽章汇总(挂载已固定), 不再单发 /count。
      expect(api.countRequestCount, 0);
      expect(find.text('产成品入库'), findsOneWidget);
      expect(
        find.byType(ModalBarrier).evaluate().length,
        baselineModalBarrierCount,
      );
      expect(
        find.descendant(
          of: find.byType(ProductionFinishedInboundTasksPage),
          matching: find.byType(ModalBarrier),
        ),
        findsNothing,
      );

      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProductionFinishedInboundTasksPage)),
      );
      container.read(pageResumeProvider.notifier).state = (
        location: RouteName.warehouse,
        tick: 1,
      );
      await tester.pumpAndSettle();
      // 其他页面的返回信号不刷新本页。
      expect(api.taskRequestCount, 1);
      container.read(pageResumeProvider.notifier).state = (
        location: RouteName.warehouseProductionFinishedInboundTasks,
        tick: 2,
      );
      await tester.pumpAndSettle();
      // 纯查看后的真实返回也重新读取服务器，避免保留页面一直显示旧任务。
      expect(api.taskRequestCount, 2);

      api.blockNextTaskRequest();
      await tester.tap(find.byTooltip('刷新'));
      await tester.pump();
      await tester.pump();
      expect(api.taskRequestCount, 3);
      final refreshSpinner = find.descendant(
        of: find.byType(UtenRefreshButton),
        matching: find.byType(CircularProgressIndicator),
      );
      expect(refreshSpinner, findsOneWidget);

      final searchField = find.descendant(
        of: find.byKey(const Key('warehouse-task-center-search')),
        matching: find.byType(TextField),
      );
      await tester.enterText(searchField, 'RB202608280001');
      // 300ms 防抖后按新关键词重拉; 期间卡住的旧刷新随后迟到, 不能覆盖新结果。
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(api.taskRequestCount, 4, reason: api.taskKeywords.toString());
      expect(api.taskKeywords.last, 'RB202608280001');
      expect(find.text('共 2 条'), findsOneWidget);
      expect(refreshSpinner, findsNothing);
      final refreshAction = tester.widget<UtenAppBarActionButton>(
        find.descendant(
          of: find.byType(UtenRefreshButton),
          matching: find.byType(UtenAppBarActionButton),
        ),
      );
      expect(refreshAction.isLoading, isFalse);
      expect(refreshAction.onPressed, isNotNull);

      api.completeBlockedTaskRequest(total: 99);
      await tester.pumpAndSettle();
      expect(
        api.taskRequestCount,
        4,
        reason:
            'The retired valid 99-row scope must not fetch continuation batches.',
      );
      expect(find.text('共 99 条'), findsNothing);
      expect(find.text('共 2 条'), findsOneWidget);

      // 单击只切换多选，不进入任何详情。
      await tester.tap(find.text('短收余量待点收'));
      await tester.pump();
      expect(find.text('已选 1 项'), findsOneWidget);
      expect(find.text('final-document-$_finalTaskId'), findsNothing);

      // 双击按任务阶段进入现有到货登记路由，保留 returnTo 与返回后的刷新。
      await _doubleTapRow(tester, find.text('待登记入库'));
      await tester.pumpAndSettle();

      expect(find.text('arrival-report-$_arrivalTaskId'), findsOneWidget);
      final pushedLocation = tester
          .widget<_RegistrationRouteProbe>(find.byType(_RegistrationRouteProbe))
          .location;
      expect(
        find.text('return-${pushedLocation.queryParameters['returnTo']}'),
        findsOneWidget,
      );
      // returnTo 记录进入时的完整地址(含 hub 带来的原 returnTo 参数),
      // 回退仍先落回本任务页。
      expect(
        Uri.parse(pushedLocation.queryParameters['returnTo']!).path,
        RouteName.warehouseProductionFinishedInboundTasks,
        reason: pushedLocation.toString(),
      );
      expect(api.taskRequestCount, 4);

      await tester.tap(find.byKey(const Key('complete-arrival-route')));
      await tester.pumpAndSettle();

      // 办理返回后由打开路径主动重拉一次列表。
      expect(api.taskRequestCount, 5);
      expect(find.text('产成品入库'), findsOneWidget);

      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('open-finished-inbound-tasks')),
        findsOneWidget,
      );
      expect(api.taskRequestCount, 5);
    },
  );

  testWidgets(
    'view-only row menu is read-only and final-count double click works',
    (tester) async {
      await setUtenTestSurfaceSize(tester, const Size(1200, 900));
      addTearDown(() => setUtenTestSurfaceSize(tester, null));
      final api = _TrackingFinishedInboundApi()..rowsHandleable = false;
      final router = _buildRouter(
        initialLocation: RouteName.warehouseProductionFinishedInboundTasks,
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        _testApp(api: api, router: router, canApprove: false),
      );
      await tester.pumpAndSettle();

      final table = tester
          .widget<MasterDataTableView<WarehouseTaskCenterRecord>>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is MasterDataTableView<WarehouseTaskCenterRecord>,
            ),
          );
      expect(table.selectable, isFalse);
      expect(table.batchActionsBuilder, isNull);
      final actionLabels = [
        for (final item in table.items)
          (table.rowMenuBuilder!(item).single as UtenMenuItem).label,
      ];
      expect(actionLabels, ['查看详情与处理进度', '查看详情与处理进度']);
      expect(
        find.byKey(const Key('warehouse-task-record-batch')),
        findsNothing,
        reason: '只读账号没有批量办理动作',
      );

      await _doubleTapRow(tester, find.text('短收余量待点收'));
      await tester.pumpAndSettle();

      expect(find.text('final-document-$_finalTaskId'), findsOneWidget);
      expect(api.taskRequestCount, 1);
    },
  );

  testWidgets(
    'registration multi-select shows both route buttons and carries the route into the batch page',
    (tester) async {
      await setUtenTestSurfaceSize(tester, const Size(1200, 900));
      addTearDown(() => setUtenTestSurfaceSize(tester, null));
      final api = _TrackingFinishedInboundApi()..allowPreStock = true;
      final router = _buildRouter(
        initialLocation: RouteName.warehouseProductionFinishedInboundTasks,
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        _testApp(
          api: api,
          router: router,
          extraPermissions: const {Perm.productionFinishedInBeforeInspection},
        ),
      );
      await tester.pumpAndSettle();

      // 未勾选时不占位显示路线按钮(旧版置灰按钮改由选择后才出现)。
      expect(find.text('先入库后质检'), findsNothing);
      expect(find.text('先质检后入库'), findsNothing);
      expect(
        find.byKey(const Key('production-finished-inbound-batch-register')),
        findsNothing,
      );

      await tester.tap(find.text('待登记入库'));
      await tester.pump();
      final stockInFirst = find.widgetWithText(UtenButton, '先入库后质检');
      final inspectFirst = find.widgetWithText(UtenButton, '先质检后入库');
      expect(stockInFirst, findsOneWidget);
      expect(inspectFirst, findsOneWidget);
      expect(
        tester.widget<UtenButton>(stockInFirst).type,
        UtenButtonType.success,
      );
      expect(
        tester.widget<UtenButton>(inspectFirst).type,
        UtenButtonType.primary,
      );

      // 「先入库后质检(N)」：进批量登记页带 preStock=1。
      await tester.tap(stockInFirst);
      await tester.pumpAndSettle();
      expect(find.byType(_RegistrationRouteProbe), findsOneWidget);
      var location = tester
          .widget<_RegistrationRouteProbe>(find.byType(_RegistrationRouteProbe))
          .location;
      expect(
        location.path,
        RouteName.warehouseProductionFinishedArrivalRegistration,
      );
      expect(location.queryParameters['reportIds'], _arrivalTaskId);
      expect(location.queryParameters['preStock'], '1');
      expect(
        location.queryParameters['returnTo'],
        RouteName.warehouseProductionFinishedInboundTasks,
      );

      // 未办理直接返回：列表刷新清空勾选，重新勾选后改点「先质检后入库(N)」带 preStock=0。
      await tester.tap(find.byKey(const Key('leave-batch-route')));
      await tester.pumpAndSettle();
      expect(find.text('先质检后入库'), findsNothing);
      await tester.tap(find.text('待登记入库'));
      await tester.pump();
      expect(find.text('先质检后入库'), findsOneWidget);
      await tester.tap(find.text('先质检后入库'));
      await tester.pumpAndSettle();
      location = tester
          .widget<_RegistrationRouteProbe>(find.byType(_RegistrationRouteProbe))
          .location;
      expect(location.queryParameters['reportIds'], _arrivalTaskId);
      expect(location.queryParameters['preStock'], '0');
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _doubleTapRow(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(finder);
  await tester.pump();
}

Widget _testApp({
  required _TrackingFinishedInboundApi api,
  required GoRouter router,
  bool canApprove = true,
  Set<String> extraPermissions = const {},
}) => ProviderScope(
  overrides: [
    ...warehouseRequestScopeFixture(
      api: api,
      includeClient: false,
      includeBadges: false,
    ),
    localServerReachableProvider.overrideWith(
      (ref) => LocalServerReachabilityNotifier(_preferences, web: true),
    ),
    sharedPreferencesProvider.overrideWithValue(_preferences),
    apiClientProvider.overrideWithValue(api),
    currentPermissionsProvider.overrideWithValue({
      Perm.stockDocView,
      if (canApprove) Perm.stockDocApprove,
      ...extraPermissions,
    }),
    isSuperAdminProvider.overrideWithValue(false),
    // ADR-184：分段红数固定为徽章事实, 不再单发 /count, 也不走真实轮询。
    fixedBadgeSummaryOverride(
      badgeSummaryFixture(facts: const {BadgeFact.finishedInbound: 2}),
    ),
  ],
  child: MaterialApp.router(routerConfig: router),
);

GoRouter _buildRouter({required String initialLocation}) => GoRouter(
  initialLocation: initialLocation,
  routes: [
    GoRoute(
      path: RouteName.warehouse,
      builder: (context, _) => Scaffold(
        body: Center(
          child: FilledButton(
            key: const Key('open-finished-inbound-tasks'),
            onPressed: () => goFrom(
              context,
              RouteName.warehouseProductionFinishedInboundTasks,
            ),
            child: const Text('打开产成品入库任务'),
          ),
        ),
      ),
    ),
    GoRoute(
      path: RouteName.warehouseProductionFinishedInboundTasks,
      builder: (_, _) => const ProductionFinishedInboundTasksPage(),
    ),
    // ADR-151 §5：单张与多选进同一个登记页，来源走 ?reportIds=(1..N)。
    GoRoute(
      path: RouteName.warehouseProductionFinishedArrivalRegistration,
      builder: (_, state) => _RegistrationRouteProbe(location: state.uri),
    ),
    GoRoute(
      path: '/warehouse/:code/:id',
      builder: (_, state) =>
          Scaffold(body: Text('final-document-${state.pathParameters['id']}')),
    ),
  ],
);

/// 登记页落点：记下任务中心 push 的完整地址(来源报工、路线参数、返回地址)。
class _RegistrationRouteProbe extends StatelessWidget {
  const _RegistrationRouteProbe({required this.location});

  final Uri location;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Text('arrival-report-${location.queryParameters['reportIds']}'),
        Text('return-${location.queryParameters['returnTo']}'),
        Text('batch-location-$location'),
        FilledButton(
          key: const Key('complete-arrival-route'),
          onPressed: () => context.pop(true),
          child: const Text('完成登记'),
        ),
        FilledButton(
          key: const Key('leave-batch-route'),
          onPressed: () => context.pop(),
          child: const Text('返回任务中心'),
        ),
      ],
    ),
  );
}

class _TrackingFinishedInboundApi extends ApiClient {
  _TrackingFinishedInboundApi() : super(Dio());

  int taskRequestCount = 0;
  int countRequestCount = 0;
  final List<String> taskKeywords = [];
  final preparationQueries = <Map<String, dynamic>>[];
  Completer<Map<String, dynamic>>? _armedBlock;
  Completer<Map<String, dynamic>>? _issuedBlock;

  /// 服务端行事实(ADR-184)：canHandle 折叠办理资格, canRegisterBeforeInspection
  /// 折叠「先入库后质检」显式权限。
  bool rowsHandleable = true;
  bool allowPreStock = false;

  void blockNextTaskRequest() {
    _armedBlock = Completer<Map<String, dynamic>>();
  }

  void completeBlockedTaskRequest({required int total}) {
    final issued = _issuedBlock;
    _issuedBlock = null;
    if (issued == null) throw StateError('No blocked task request');
    issued.complete(_taskPayload(total: total));
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/count')) {
      countRequestCount++;
      return const {'count': 2};
    }
    if (path != '/warehouse/task-center/inbound') {
      throw StateError('Unexpected request: $path');
    }
    if (query?['source'] != 'FINISHED') {
      expectSync(query?['source'], isIn(['OTHER', 'RETURN', 'ALL']));
      expectSync(query?['page'], 1);
      expectSync(query?['view'], 'ACTIVE');
      preparationQueries.add(Map<String, dynamic>.of(query!));
      return query['source'] == 'ALL'
          ? _taskPayload()
          : {..._taskPayload(total: 0), 'items': <Map<String, dynamic>>[]};
    }
    taskRequestCount++;
    taskKeywords.add(query?['keyword'] as String? ?? '');
    // 只拦截下一次请求(刷新), 防抖后的关键词请求走正常数据。
    final blocked = _armedBlock;
    _armedBlock = null;
    if (blocked != null && !blocked.isCompleted) {
      _issuedBlock = blocked;
      return blocked.future;
    }
    return _taskPayload();
  }

  Map<String, dynamic> _taskPayload({int total = 2}) {
    final rows = <Map<String, dynamic>>[
      {
        'rowKey': _registerRowKey,
        'id': _arrivalTaskId,
        'sourceType': 'FINISHED',
        'recordType': 'FINISHED_ARRIVAL_REPORT',
        'status': 'FINISHED_REGISTER',
        'statusLabel': '待登记入库',
        'billNo': 'SJ202608270001',
        'businessDate': '2026-08-28',
        'warehouseName': '半成品仓',
        'action': 'FINISHED_REGISTER',
        'targetId': _arrivalTaskId,
        'canHandle': rowsHandleable,
        'actionData': {
          'reportId': _arrivalTaskId,
          'canRegisterBeforeInspection': allowPreStock,
        },
      },
      {
        'rowKey': _finalRowKey,
        'id': _finalTaskId,
        'sourceType': 'FINISHED',
        'recordType': 'FINISHED_IN_DOCUMENT',
        'status': 'FINAL_COUNT',
        'statusLabel': '短收余量待点收',
        'billNo': 'CPRK202608280001',
        'businessDate': '2026-08-28',
        'warehouseName': '半成品仓',
        'action': 'FINISHED_COUNT',
        'targetId': _finalTaskId,
        'canHandle': rowsHandleable,
        'actionData': {
          'taskId': _finalTaskId,
          'documentId': _finalTaskId,
          'pendingQty': 1000,
        },
      },
    ];
    for (var index = 2; index < total; index++) {
      final id = '30000000-0000-4000-8000-${index.toString().padLeft(12, '0')}';
      rows.add({
        ...rows.first,
        'rowKey': 'FINISHED:FINISHED_REGISTER:$id',
        'id': id,
        'targetId': id,
        'billNo': 'SJ-LATE-$index',
        'actionData': {
          'reportId': id,
          'canRegisterBeforeInspection': allowPreStock,
        },
      });
    }
    return {
      'items': rows.take(total).take(40).toList(),
      'page': 1,
      'size': 40,
      'total': total,
      'totalPages': (total + 39) ~/ 40,
      'facets': const <String, dynamic>{},
    };
  }
}
