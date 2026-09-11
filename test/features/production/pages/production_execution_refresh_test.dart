import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/production/models/production_execution_workbench.dart';
import 'package:uten_imp/features/production/pages/production_workshop_tasks_page.dart';
import 'package:uten_imp/features/production/providers/production_department_provider.dart';
import 'package:uten_imp/features/production/providers/production_execution_refresh.dart';
import 'package:uten_imp/features/production/repositories/production_execution_workbench_repository.dart';
import 'package:uten_imp/features/production/widgets/production_execution_group_panel.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/list_refresh_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

void main() {
  testWidgets('workshop tasks refresh on plan generation and route return', (
    tester,
  ) async {
    final repository = _Repository();
    final container = await _pump(
      tester,
      repository,
      const ProductionWorkshopTasksPage(),
    );
    // 分类默认不选：初始不发列表请求，点分类才加载。
    expect(repository.taskLoads, 0);
    // 2026-09-06 改版：「可报工」分类退役，报工归「生产中」。
    await tester.tap(find.text('生产中'));
    await tester.pumpAndSettle();
    expect(repository.taskLoads, 1);
    expect(repository.statuses, ['IN_PROGRESS']);
    expect(find.text('车间任务 1'), findsOneWidget);
    container
        .read(listRefreshTickProvider(productionExecutionRefreshKey).notifier)
        .state++;
    await tester.pumpAndSettle();
    expect(repository.taskLoads, 2);
    expect(find.text('车间任务 2'), findsOneWidget);
    container.read(pageResumeProvider.notifier).state = (
      location: '/other',
      tick: 1,
    );
    container.read(pageResumeProvider.notifier).state = (
      location: RouteName.productionWorkshopTasks,
      tick: 2,
    );
    await tester.pumpAndSettle();
    expect(repository.taskLoads, 3);
    expect(find.text('车间任务 3'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });

  testWidgets(
    'ongoing production refreshes its current group after plan generation',
    (tester) async {
      final repository = _Repository();
      final container = await _pump(
        tester,
        repository,
        const Scaffold(body: ProductionExecutionGroupPanel(keyword: '')),
      );
      expect(repository.groupLoads, 1);
      expect(find.text('生产批次 1'), findsOneWidget);
      container
          .read(listRefreshTickProvider(productionExecutionRefreshKey).notifier)
          .state++;
      await tester.pumpAndSettle();
      expect(repository.groupLoads, 2);
      expect(find.text('生产批次 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    },
  );
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Repository repository,
  Widget home,
) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      sessionProvider.overrideWith(_Session.new),
      currentPermissionsProvider.overrideWithValue(const {
        Perm.productionExecutionView,
        Perm.productionExecutionOverview,
      }),
      isSuperAdminProvider.overrideWithValue(false),
      productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
        repository,
      ),
      productionWorkshopTreeProvider.overrideWith((ref) async => []),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: home),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _Repository extends ProductionExecutionWorkbenchRepository {
  _Repository() : super(ApiClient(Dio()));
  int taskLoads = 0;
  int groupLoads = 0;
  final List<String?> statuses = [];

  @override
  Future<PagedResult<ProductionExecutionWorkbenchSegment>> workshopTasks({
    int page = 1,
    int size = 50,
    String keyword = '',
    String? status,
    String? workshopDepartmentId,
    String? dateFrom,
    String? dateTo,
  }) async {
    statuses.add(status);
    taskLoads++;
    return PagedResult(
      items: [
        ProductionExecutionWorkbenchSegment.fromJson({
          'segmentId': 'segment',
          'planId': 'plan',
          'planNo': 'SJ-1',
          'productName': '车间任务 $taskLoads',
          'segmentStatus': 'WAITING',
          'preparationStatus': 'PREPARING',
          'materialStatus': 'SHORTAGE',
          'plannedQty': 10,
          'canReport': false,
          'canBatchReport': false,
        }),
      ],
      page: 1,
      size: 50,
      total: 1,
      totalPages: 1,
    );
  }

  @override
  Future<WorkshopTaskCountBreakdown> workshopTaskCount() async =>
      const WorkshopTaskCountBreakdown(count: 1);

  @override
  Future<PagedResult<ProductionExecutionWorkbenchGroup>> groups({
    int page = 1,
    int size = 50,
    String keyword = '',
    String? workshopDepartmentId,
    String sort = 'latestEndDate',
    String order = 'asc',
  }) async {
    groupLoads++;
    return PagedResult(
      items: [
        ProductionExecutionWorkbenchGroup.fromJson({
          'rootType': 'ANALYSIS',
          'rootId': 'analysis',
          'rootLabel': '生产批次 $groupLoads',
          'status': 'PREPARING',
          'planCount': 1,
          'segmentCount': 1,
        }),
      ],
      page: 1,
      size: 50,
      total: 1,
      totalPages: 1,
    );
  }
}
