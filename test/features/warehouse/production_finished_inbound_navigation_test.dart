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
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/router/nav_helpers.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/models/production_finished_inbound_task.dart';
import 'package:uten_imp/features/warehouse/pages/production_finished_inbound_tasks_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

const _arrivalTaskId = '20000000-0000-0000-0000-000000000001';
const _finalTaskId = '10000000-0000-0000-0000-000000000001';

late SharedPreferences _preferences;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });
  testWidgets(
    'hub entry loads once and refresh search arrival return stay operable',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
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
      expect(api.countRequestCount, 0);
      expect(find.text('产成品入库任务'), findsOneWidget);
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
      await tester.pump();
      container.read(pageResumeProvider.notifier).state = (
        location: RouteName.warehouseProductionFinishedInboundTasks,
        tick: 2,
      );
      await tester.pumpAndSettle();
      expect(api.taskRequestCount, 1);

      api.blockNextTaskRequest();
      await tester.tap(
        find.byKey(const Key('production-finished-inbound-refresh')),
      );
      // 2026-09-01 起正文抽成 View：加载态经 onLoadingChanged 回传独立页 AppBar，
      // 置灰在第二帧生效（tap 帧 + post-frame 加载帧）。
      await tester.pump();
      await tester.pump();
      expect(api.taskRequestCount, 2);
      // 2026-09-11 起顶栏动作统一走 UtenAppBarActionButton（与「权限设置」同高 36）。
      expect(
        tester
            .widget<UtenAppBarActionButton>(
              find.byKey(const Key('production-finished-inbound-refresh')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(
        find.byKey(const Key('production-finished-inbound-refresh')),
      );
      await tester.pump();
      expect(api.taskRequestCount, 2);

      final searchField = find.descendant(
        of: find.byKey(const Key('production-finished-inbound-search')),
        matching: find.byType(TextField),
      );
      await tester.enterText(searchField, 'RB202608280001');
      await tester.pump();
      api.completeBlockedTaskRequest(total: 99);
      await tester.pump();

      expect(find.text('共 99 项 · 单击多选，双击详情'), findsNothing);
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();

      expect(api.taskRequestCount, 3, reason: api.taskKeywords.toString());
      expect(api.taskKeywords.last, 'RB202608280001');
      expect(find.text('共 2 项 · 单击多选，双击详情'), findsOneWidget);

      // 单击只切换多选，不进入任何详情。
      await tester.tap(find.text('短收余量待点收'));
      await tester.pump();
      expect(find.text('已选 1 项'), findsOneWidget);
      expect(find.text('final-document-$_finalTaskId'), findsNothing);

      // 双击按任务阶段进入现有到货登记路由，保留 returnTo 与返回后的刷新。
      await _doubleTapRow(tester, find.text('待登记入库'));
      await tester.pumpAndSettle();

      expect(find.text('arrival-report-$_arrivalTaskId'), findsOneWidget);
      expect(
        find.text(
          'return-${RouteName.warehouseProductionFinishedInboundTasks}',
        ),
        findsOneWidget,
      );
      expect(api.taskRequestCount, 3);

      await tester.tap(find.byKey(const Key('complete-arrival-route')));
      await tester.pumpAndSettle();

      expect(api.taskRequestCount, 4);
      expect(find.text('产成品入库任务'), findsOneWidget);

      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('open-finished-inbound-tasks')),
        findsOneWidget,
      );
      expect(api.taskRequestCount, 4);
    },
  );

  testWidgets(
    'view-only row menu is read-only and final-count double click works',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _TrackingFinishedInboundApi();
      final router = _buildRouter(
        initialLocation: RouteName.warehouseProductionFinishedInboundTasks,
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        _testApp(api: api, router: router, canApprove: false),
      );
      await tester.pumpAndSettle();

      final table = tester
          .widget<MasterDataTableView<ProductionFinishedInboundTask>>(
            find.byKey(const Key('production-finished-inbound-task-table')),
          );
      expect(table.selectable, isFalse);
      expect(table.batchActionsBuilder, isNull);
      final actionLabels = [
        for (final item in table.items)
          (table.rowMenuBuilder!(item).single as UtenMenuItem).label,
      ];
      expect(actionLabels, ['查看到货登记详情', '查看待点收详情']);
      expect(
        find.byKey(
          const ValueKey('finished-inbound-task-action-$_finalTaskId'),
        ),
        findsNothing,
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
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _TrackingFinishedInboundApi();
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

      // 待登记阶段：与预计到货同款两颗路线按钮并排(未勾选时置灰、不带计数)。
      const stockInFirst = Key('inbound-route-batch-stockInFirst');
      const inspectFirst = Key('inbound-route-batch-inspectFirst');
      expect(find.byKey(stockInFirst), findsOneWidget);
      expect(find.byKey(inspectFirst), findsOneWidget);
      expect(find.text('先入库后质检'), findsOneWidget);
      expect(find.text('先质检后入库'), findsOneWidget);
      expect(
        find.byKey(const Key('production-finished-inbound-batch-register')),
        findsNothing,
      );

      await tester.tap(find.text('待登记入库'));
      await tester.pump();
      expect(find.text('先入库后质检(1)'), findsOneWidget);
      expect(find.text('先质检后入库(1)'), findsOneWidget);

      // 「先入库后质检(N)」：进批量登记页带 preStock=1。
      await tester.tap(find.byKey(stockInFirst));
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

      // 未办理直接返回：勾选保留，改点「先质检后入库(N)」带 preStock=0。
      await tester.tap(find.byKey(const Key('leave-batch-route')));
      await tester.pumpAndSettle();
      expect(find.text('先质检后入库(1)'), findsOneWidget);
      await tester.tap(find.byKey(inspectFirst));
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
  int facetRequestCount = 0;
  final List<String> taskKeywords = [];
  Completer<Map<String, dynamic>>? _blockedTaskRequest;

  void blockNextTaskRequest() {
    _blockedTaskRequest = Completer<Map<String, dynamic>>();
  }

  void completeBlockedTaskRequest({required int total}) {
    final blocked = _blockedTaskRequest;
    if (blocked == null) throw StateError('No blocked task request');
    blocked.complete(_taskPayload(total: total));
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.productionFinishedInboundTaskFacets) {
      facetRequestCount++;
      return const {};
    }
    if (path.endsWith('/count')) {
      countRequestCount++;
      return const {'count': 2};
    }
    if (path != ApiEndpoints.productionFinishedInboundTasks) {
      throw StateError('Unexpected request: $path');
    }
    taskRequestCount++;
    taskKeywords.add(query?['keyword'] as String? ?? '');
    final blocked = _blockedTaskRequest;
    if (blocked != null && !blocked.isCompleted) {
      return blocked.future;
    }
    return _taskPayload();
  }

  Map<String, dynamic> _taskPayload({int total = 2}) => {
    'items': const [
      {
        'taskStage': 'ARRIVAL_REGISTRATION',
        'taskId': _arrivalTaskId,
        'reportId': _arrivalTaskId,
        'documentId': null,
        'documentNo': null,
        'documentDate': '2026-08-28',
        'planNo': 'SJ202608270001',
        'reportNos': 'RB202608280001',
        'goodsSummary': 'V5多功能三极插座E极插套(酸洗)',
        'lineCount': 1,
        'pendingQty': 1000,
        'createdAt': '2026-08-28T04:00:00Z',
        'residualTask': false,
      },
      {
        'taskStage': 'FINAL_COUNT',
        'taskId': _finalTaskId,
        'reportId': _arrivalTaskId,
        'documentId': _finalTaskId,
        'documentNo': 'CPRK202608280001',
        'documentDate': '2026-08-28',
        'warehouseId': '10000000-0000-0000-0000-000000000002',
        'warehouseName': '半成品仓',
        'planNo': 'SJ202608280001',
        'reportNos': 'RB202608280001',
        'goodsSummary': 'V5多功能三极插座E极插套(酸洗)',
        'lineCount': 1,
        'pendingQty': 1000,
        'createdAt': '2026-08-28T05:00:00Z',
        'residualTask': true,
      },
    ],
    'page': 1,
    'size': 40,
    'total': total,
    'totalPages': 1,
  };
}
