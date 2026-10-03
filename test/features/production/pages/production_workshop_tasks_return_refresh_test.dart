// 车间任务页「批量报工 -> 日报新建页保存 -> 详情页返回」的真实导航链路回归。
//
// 2026-09-20 用户反馈：从生产日报详情页返回「我的车间任务」不刷新，已报完工的
// 行还挂在「生产中」；之后勾选行也开不了工，右上角刷新无效，只有浏览器刷新才好。
// 根因：日报新建页保存后 `context.replace` 换成详情页，go_router 的 replace 会
// 丢弃原 push 的 completer——车间任务页 `await context.push(...)` 永远不返回，
// `_navigating` 卡在 true。本测试用与 app_router 同一份 attachPageResume 接线
// 复现整条链路，锁定：返回后必须重拉列表，且动作按钮必须能再次进入。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/core/network/server_selection.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/data_write_revision.dart';
import 'package:uten_imp/core/router/nav_helpers.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/production/pages/production_workshop_tasks_page.dart';
import 'package:uten_imp/features/production/repositories/production_execution_workbench_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';

import '../../../helpers/badge_summary_fixture.dart';
import '../../../support/filter_segment_tap.dart';

late SharedPreferences _preferences;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });
  testWidgets(
    'saved draft opens review and completes both route futures on return',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var loads = 0;
      String? reviewOrigin;
      final router = GoRouter(
        initialLocation: RouteName.productionWorkshopTasks,
        routes: [
          GoRoute(
            path: RouteName.productionWorkshopTasks,
            builder: (_, _) => const ProductionWorkshopTasksPage(),
          ),
          GoRoute(
            path: '/production/daily-reports/new',
            builder: (context, _) => Scaffold(
              body: ElevatedButton(
                onPressed: () => context.pop('saved-report'),
                child: const Text('保存报工草稿'),
              ),
            ),
          ),
          GoRoute(
            path: '/production/daily-reports/:id',
            builder: (context, state) {
              reviewOrigin = state.uri.queryParameters['from'];
              return Scaffold(
                body: ElevatedButton(
                  onPressed: () => context.pop(),
                  child: Text('审核 ${state.pathParameters['id']}'),
                ),
              );
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      final container = ProviderContainer(
        overrides: [
          localServerReachableProvider.overrideWith(
            (ref) => LocalServerReachabilityNotifier(_preferences, web: true),
          ),
          sharedPreferencesProvider.overrideWithValue(_preferences),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.productionExecutionView,
            Perm.productionDailyReportView,
            Perm.productionDailyReportCreate,
          }),
          productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
            _repository(() => loads++),
          ),
          fixedBadgeSummaryOverride(badgeSummaryFixture()),
        ],
      );
      // No page-resume fallback: both ordinary push futures must really complete.
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      await selectFilterSegment(tester, '生产中');
      await tester.pumpAndSettle();
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is Checkbox && widget.tristate,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('批量报工(1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存报工草稿'));
      await tester.pumpAndSettle();
      expect(find.text('审核 saved-report'), findsOneWidget);
      expect(reviewOrigin, 'workshop-tasks');
      expect(
        loads,
        1,
        reason: 'Save must continue to review before finishing the task flow',
      );
      await tester.tap(find.text('审核 saved-report'));
      await tester.pumpAndSettle();
      expect(loads, 2);
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is Checkbox && widget.tristate,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('批量报工(1)'));
      await tester.pumpAndSettle();
      expect(find.text('保存报工草稿'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    },
  );

  testWidgets(
    'returning from a replaced daily report detail refreshes tasks and re-enables actions',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var loads = 0;
      final router = GoRouter(
        initialLocation: RouteName.productionWorkshopTasks,
        routes: [
          GoRoute(
            path: RouteName.productionWorkshopTasks,
            builder: (_, _) => const ProductionWorkshopTasksPage(),
          ),
          GoRoute(
            path: '/production/daily-reports/new',
            builder: (_, _) => Scaffold(
              body: Center(
                child: Consumer(
                  builder: (context, ref, _) => ElevatedButton(
                    // 与 production_daily_report_edit_page._save 同款：
                    // 保存(真实环境里网络层会推进本端写修订号, ADR-108)后
                    // replace 成详情页。
                    onPressed: () {
                      ref.read(dataWriteRevisionProvider.notifier).state++;
                      context.replace('/production/daily-reports/r1');
                    },
                    child: const Text('保存日报'),
                  ),
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/production/daily-reports/:id',
            builder: (_, _) => Scaffold(
              body: Center(
                child: Builder(
                  builder: (context) => ElevatedButton(
                    // 与详情页 UtenAppBar 返回键同款：backTo 优先 pop。
                    onPressed: () => backTo(
                      context,
                      defaultPath: RouteName.productionDailyReportList,
                    ),
                    child: const Text('详情返回'),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      final container = ProviderContainer(
        overrides: [
          localServerReachableProvider.overrideWith(
            (ref) => LocalServerReachabilityNotifier(_preferences, web: true),
          ),
          sharedPreferencesProvider.overrideWithValue(_preferences),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.productionExecutionView,
            Perm.productionDailyReportView,
            Perm.productionDailyReportCreate,
          }),
          productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
            _repository(() => loads++),
          ),
          fixedBadgeSummaryOverride(badgeSummaryFixture()),
        ],
      );
      addTearDown(
        attachPageResume(router, container.read(pageResumeProvider.notifier)),
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      await selectFilterSegment(tester, '生产中');
      await tester.pumpAndSettle();
      expect(loads, 1);

      Future<void> openBatchReport() async {
        await tester.tap(
          find.byWidgetPredicate(
            (widget) => widget is Checkbox && widget.tristate,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('批量报工(1)'));
        await tester.pumpAndSettle();
      }

      await openBatchReport();
      expect(find.text('保存日报'), findsOneWidget);
      await tester.tap(find.text('保存日报'));
      await tester.pumpAndSettle();
      expect(find.text('详情返回'), findsOneWidget);

      await tester.tap(find.text('详情返回'));
      await tester.pumpAndSettle();
      expect(find.byType(ProductionWorkshopTasksPage), findsOneWidget);
      expect(loads, 2, reason: '从详情页返回必须重拉车间任务列表');

      // 返回后动作必须能再次进入：_navigating 若卡在 true，批量报工会静默不动。
      await openBatchReport();
      expect(find.text('保存日报'), findsOneWidget, reason: '返回后再次批量报工必须能进入日报新建页');
      expect(tester.takeException(), isNull);
      // 计数徽章的 60s 轮询定时器归 container 所有：先卸树再释放，避免挂起定时器。
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    },
  );

  testWidgets('toolbar refresh clears a stuck navigating flag', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var loads = 0;
    final router = GoRouter(
      initialLocation: RouteName.productionWorkshopTasks,
      routes: [
        GoRoute(
          path: RouteName.productionWorkshopTasks,
          builder: (_, _) => const ProductionWorkshopTasksPage(),
        ),
        GoRoute(
          path: '/production/daily-reports/new',
          builder: (_, _) => Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => ElevatedButton(
                  // 保存后 replace 成详情页，再用 go 整栈回到车间任务页：
                  // 原 push 的 Future 永远不完成，「返回即刷新」也不经过 pop。
                  onPressed: () =>
                      context.replace('/production/daily-reports/r1'),
                  child: const Text('保存日报'),
                ),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/production/daily-reports/:id',
          builder: (_, _) => Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () =>
                      context.go(RouteName.productionWorkshopTasks),
                  child: const Text('回车间任务'),
                ),
              ),
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    final container = ProviderContainer(
      overrides: [
        localServerReachableProvider.overrideWith(
          (ref) => LocalServerReachabilityNotifier(_preferences, web: true),
        ),
        sharedPreferencesProvider.overrideWithValue(_preferences),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.productionExecutionView,
          Perm.productionDailyReportView,
          Perm.productionDailyReportCreate,
        }),
        productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
          _repository(() => loads++),
        ),
        fixedBadgeSummaryOverride(badgeSummaryFixture()),
      ],
    );
    // 故意不接 attachPageResume：模拟「返回即刷新」没有触发的最坏情况，
    // 右上角刷新按钮自己就得把页面拉回可用。
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await selectFilterSegment(tester, '生产中');
    await tester.pumpAndSettle();
    expect(loads, 1);

    await tester.tap(
      find.byWidgetPredicate((widget) => widget is Checkbox && widget.tristate),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('批量报工(1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存日报'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('回车间任务'));
    await tester.pumpAndSettle();
    expect(find.byType(ProductionWorkshopTasksPage), findsOneWidget);

    // 页面实例被 go 保留：勾选还在，但 _navigating 可能卡着。右上角刷新必须
    // 把它复位，之后批量报工要能进入。
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(loads, greaterThanOrEqualTo(2));
    if (!tester.any(find.text('批量报工(1)'))) {
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is Checkbox && widget.tristate,
        ),
      );
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('批量报工(1)'));
    await tester.pumpAndSettle();
    expect(find.text('保存日报'), findsOneWidget, reason: '刷新后批量报工必须能进入日报新建页');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });
  // 2026-09-26 用户口径：未审核报工草稿（SR status=0）承接的数量要从「生产中」的
  // 待报里扣除——全部承接时待办**离段**（正文行与分段计数一起消失，行改从「草稿」
  // 段看）；部分承接保留分批报工（显示扣减后的待报）；「草稿」段合并我的服务端
  // 报工草稿（行可跳日报详情）；删除草稿后重拉即恢复。
  for (final (initialClaim, expectedRemaining) in [
    (8000.0, '0'),
    (3000.0, '5000'),
  ]) {
    testWidgets(
      'draft claim $initialClaim deducts the reportable quantity (remaining $expectedRemaining)',
      (tester) async {
        var claim = initialClaim;
        await tester.binding.setSurfaceSize(const Size(1600, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final api = _draftClaimingApi(claimedQty: () => claim);
        final container = ProviderContainer(
          overrides: [
            localServerReachableProvider.overrideWith(
              (ref) => LocalServerReachabilityNotifier(_preferences, web: true),
            ),
            sharedPreferencesProvider.overrideWithValue(_preferences),
            apiClientProvider.overrideWithValue(api),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.productionExecutionView,
              Perm.productionDailyReportView,
              Perm.productionDailyReportCreate,
            }),
            // 「生产中」黄徽章计数（服务端口径 3）：全量承接时显示 3-1=2。
            fixedBadgeSummaryOverride(
              badgeSummaryFixture(facts: {BadgeFact.workshopInProgress: 3}),
            ),
          ],
        );
        addTearDown(container.dispose);
        final router = GoRouter(
          initialLocation: RouteName.productionWorkshopTasks,
          routes: [
            GoRoute(
              path: RouteName.productionWorkshopTasks,
              builder: (_, _) => const ProductionWorkshopTasksPage(),
            ),
            GoRoute(
              path: '/production/daily-reports/:id',
              builder: (context, state) =>
                  Scaffold(body: Text('日报详情 ${state.pathParameters['id']}')),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await tester.pumpAndSettle();
        await selectFilterSegment(tester, '生产中');
        await tester.pumpAndSettle();

        // 表头三态全选格是唯一 tristate Checkbox：勾它即选全部可选行。
        final selectAll = find.byWidgetPredicate(
          (w) => w is Checkbox && w.tristate,
        );
        if (claim >= 8000) {
          // 全量承接：正文行与「报工草稿待审核」徽章一起离段，指路「草稿」段；
          // 分段计数 3-1=2（不是 3，也不再出现 1 行的旧行为）。
          expect(find.text('报工草稿待审核'), findsNothing);
          expect(find.text('产品 A'), findsNothing);
          expect(find.textContaining('待报都已由报工草稿承接'), findsOneWidget);
          expect(find.text('2'), findsOneWidget);
        } else {
          expect(find.textContaining('生产中 · 可报工'), findsOneWidget);
          expect(find.text('3'), findsOneWidget, reason: '部分承接不减计数');
          await tester.tap(selectAll);
          await tester.pumpAndSettle();
          expect(find.text('批量报工(1)'), findsOneWidget, reason: '部分承接保留分批报工');
        }

        // 「草稿」段：我的服务端报工草稿与本地草稿共用一张表，行可跳日报详情。
        await selectFilterSegment(tester, '草稿');
        await tester.pumpAndSettle();
        expect(find.text('SR-DRAFT-1'), findsOneWidget);
        expect(find.text('草稿'), findsAtLeastNWidgets(1));
        await tester.tap(find.text('SR-DRAFT-1'));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.text('SR-DRAFT-1'));
        await tester.pumpAndSettle();
        expect(find.text('日报详情 draft-1'), findsOneWidget);
        tester.state<NavigatorState>(find.byType(Navigator).first).pop();
        await tester.pumpAndSettle();

        await selectFilterSegment(tester, '生产中');
        await tester.pumpAndSettle();

        // 列表行是「单击选中、双击打开」：双击产品名称打开任务详情。
        Future<void> openTaskDetail() async {
          await tester.tap(find.text('产品 A'));
          await tester.pump(const Duration(milliseconds: 50));
          await tester.tap(find.text('产品 A'));
          await tester.pumpAndSettle();
        }

        if (claim < 8000) {
          await openTaskDetail();
          expect(
            find.textContaining('待报数量（含品质恢复）：$expectedRemaining'),
            findsOneWidget,
          );
          expect(
            find.textContaining('报工草稿待审核 ${claim.toStringAsFixed(0)}'),
            findsOneWidget,
          );
          await tester.tap(find.text('关闭'));
          await tester.pumpAndSettle();
          // 部分承接变体此刻勾着行：先清掉，让「恢复」阶段从空勾选开始。
          await tester.tap(selectAll);
          await tester.pumpAndSettle();
        }

        // 删除草稿后待办恢复：草稿清空 → 刷新 → 待报回到 8000、可再次勾选报工，
        // 计数回到服务端口径 3，「草稿」段不再显示服务端行。
        claim = 0;
        await tester.tap(find.byTooltip('刷新'));
        await tester.pumpAndSettle();
        expect(find.textContaining('生产中 · 可报工'), findsOneWidget);
        expect(find.text('3'), findsOneWidget);
        await tester.tap(selectAll);
        await tester.pumpAndSettle();
        expect(find.text('批量报工(1)'), findsOneWidget, reason: '草稿删除后待办必须恢复');
        await openTaskDetail();
        expect(find.textContaining('待报数量（含品质恢复）：8000'), findsOneWidget);
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        await selectFilterSegment(tester, '草稿');
        await tester.pumpAndSettle();
        expect(find.text('SR-DRAFT-1'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  // 2026-09-26 用户口径（fail-open）：报工草稿读取失败时不扣「生产中」、不并
  // 「草稿」段——与未上线本口径时的显示一致，绝不把没报的说成已报完。
  testWidgets('draft read failure keeps the old display (fail-open)', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _draftFailingApi();
    final container = ProviderContainer(
      overrides: [
        localServerReachableProvider.overrideWith(
          (ref) => LocalServerReachabilityNotifier(_preferences, web: true),
        ),
        sharedPreferencesProvider.overrideWithValue(_preferences),
        apiClientProvider.overrideWithValue(api),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.productionExecutionView,
          Perm.productionDailyReportView,
          Perm.productionDailyReportCreate,
        }),
        fixedBadgeSummaryOverride(badgeSummaryFixture()),
      ],
    );
    addTearDown(container.dispose);
    final router = GoRouter(
      initialLocation: RouteName.productionWorkshopTasks,
      routes: [
        GoRoute(
          path: RouteName.productionWorkshopTasks,
          builder: (_, _) => const ProductionWorkshopTasksPage(),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await selectFilterSegment(tester, '生产中');
    await tester.pumpAndSettle();
    // 草稿读不回来：行保持可报、不显示「报工草稿待审核」。
    expect(find.textContaining('生产中 · 可报工'), findsOneWidget);
    expect(find.text('报工草稿待审核'), findsNothing);
    await tester.tap(
      find.byWidgetPredicate((w) => w is Checkbox && w.tristate),
    );
    await tester.pumpAndSettle();
    expect(find.text('批量报工(1)'), findsOneWidget);
    await selectFilterSegment(tester, '草稿');
    await tester.pumpAndSettle();
    // 「草稿」段退回只显示本地草稿，并说明读取失败。
    expect(
      find.byKey(const Key('workshop-server-draft-error')),
      findsOneWidget,
    );
    expect(find.text('SR-DRAFT-1'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

/// 车间任务 + 未审核报工草稿的假 API：GD-a 计划/待报 8000，草稿按 [claimedQty]
/// 闭包实时承接（测试里改闭包变量即可模拟删除草稿后的下一次刷新）。
ApiClient _draftClaimingApi({required double Function() claimedQty}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        final data = switch (request.path) {
          '/production/workshop-tasks' => {
            'items': [
              {
                'segmentId': 'segment-a',
                'planId': 'plan-a',
                'planNo': 'SJ-a',
                'segmentCode': 'GD-a',
                'workshopDepartmentId': 'workshop-1',
                'workshopName': '装配一车间',
                'productCode': 'P-a',
                'productName': '产品 A',
                'productColorName': '本色',
                'productUnitName': '件',
                'plannedQty': 8000,
                'reportedQty': 0,
                'remainingReportQty': 8000,
                'segmentStatus': 'IN_PROGRESS',
                'materialStatus': 'KIT_READY',
                'preparationStatus': 'PREPARED',
                'materialReady': true,
                'warehouseReady': true,
                'issued': true,
                'canStart': false,
                'canReport': true,
                'canBatchReport': true,
                'lockVersion': 1,
                'startRoute': 'FULL_KIT',
              },
            ],
            'page': 1,
            'size': 50,
            'total': 1,
            'totalPages': 1,
          },
          '/production/workshop-tasks/count' => {'count': 1},
          '/production/daily-reports' => () {
            final claim = claimedQty();
            return {
              'items': claim > 0
                  ? [
                      {'id': 'draft-1', 'billNo': 'SR-DRAFT-1', 'status': 0},
                    ]
                  : <Map<String, dynamic>>[],
              'page': 1,
              'size': 100,
              'total': claim > 0 ? 1 : 0,
              'totalPages': 1,
            };
          }(),
          '/production/daily-reports/draft-1' => {
            'id': 'draft-1',
            'billNo': 'SR-DRAFT-1',
            'status': 0,
            'items': [
              {
                'id': 'draft-item-1',
                'qty': claimedQty(),
                'executionSegmentId': 'segment-a',
                'actualSurplus': false,
              },
            ],
          },
          _ => <String, dynamic>{},
        };
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: data,
          ),
        );
      },
    ),
  );
  return ApiClient(dio);
}

/// 车间任务正常、报工草稿列表读取失败（500）的假 API：验证 fail-open——
/// 「生产中」不扣减、「草稿」段退回只显示本地草稿并说明原因。
ApiClient _draftFailingApi() {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        if (request.path == '/production/daily-reports') {
          handler.reject(
            DioException.connectionError(
              requestOptions: request,
              reason: 'server unreachable',
            ),
          );
          return;
        }
        final data = switch (request.path) {
          '/production/workshop-tasks' => {
            'items': [
              {
                'segmentId': 'segment-a',
                'planId': 'plan-a',
                'planNo': 'SJ-a',
                'segmentCode': 'GD-a',
                'workshopDepartmentId': 'workshop-1',
                'workshopName': '装配一车间',
                'productCode': 'P-a',
                'productName': '产品 A',
                'productColorName': '本色',
                'productUnitName': '件',
                'plannedQty': 8000,
                'reportedQty': 0,
                'remainingReportQty': 8000,
                'segmentStatus': 'IN_PROGRESS',
                'materialStatus': 'KIT_READY',
                'preparationStatus': 'PREPARED',
                'materialReady': true,
                'warehouseReady': true,
                'issued': true,
                'canStart': false,
                'canReport': true,
                'canBatchReport': true,
                'lockVersion': 1,
                'startRoute': 'FULL_KIT',
              },
            ],
            'page': 1,
            'size': 50,
            'total': 1,
            'totalPages': 1,
          },
          '/production/workshop-tasks/count' => {'count': 1},
          _ => <String, dynamic>{},
        };
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: data,
          ),
        );
      },
    ),
  );
  return ApiClient(dio);
}

ProductionExecutionWorkbenchRepository _repository(void Function() onLoad) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        final data = switch (request.path) {
          '/production/workshop-tasks' => () {
            onLoad();
            return {
              'items': [
                {
                  'segmentId': 'segment-a',
                  'planId': 'plan-a',
                  'planNo': 'SJ-a',
                  'segmentCode': 'GD-a',
                  'workshopDepartmentId': 'workshop-1',
                  'workshopName': '装配一车间',
                  'productCode': 'P-a',
                  'productName': '产品 A',
                  'productColorName': '本色',
                  'productUnitName': '件',
                  'plannedQty': 10,
                  'reportedQty': 2,
                  'remainingReportQty': 8,
                  'segmentStatus': 'IN_PROGRESS',
                  'materialStatus': 'KIT_READY',
                  'preparationStatus': 'PREPARED',
                  'materialReady': true,
                  'warehouseReady': true,
                  'issued': true,
                  'canStart': false,
                  'canReport': true,
                  'canBatchReport': true,
                  'lockVersion': 1,
                  'startRoute': 'FULL_KIT',
                },
              ],
              'page': 1,
              'size': 50,
              'total': 1,
              'totalPages': 1,
            };
          }(),
          '/production/workshop-tasks/count' => {'count': 1},
          _ => <String, dynamic>{},
        };
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: data,
          ),
        );
      },
    ),
  );
  return ProductionExecutionWorkbenchRepository(ApiClient(dio));
}
