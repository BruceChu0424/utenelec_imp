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
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/data_write_revision.dart';
import 'package:uten_imp/core/router/nav_helpers.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/production/pages/production_workshop_tasks_page.dart';
import 'package:uten_imp/features/production/repositories/production_execution_workbench_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

import '../../../support/filter_segment_tap.dart';

void main() {
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
          currentPermissionsProvider.overrideWithValue(const {
            Perm.productionExecutionView,
            Perm.productionDailyReportView,
            Perm.productionDailyReportCreate,
          }),
          productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
            _repository(() => loads++),
          ),
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
        currentPermissionsProvider.overrideWithValue(const {
          Perm.productionExecutionView,
          Perm.productionDailyReportView,
          Perm.productionDailyReportCreate,
        }),
        productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
          _repository(() => loads++),
        ),
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
