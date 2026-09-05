import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/repositories/production_execution_workbench_repository.dart';
import 'package:uten_imp/features/production/widgets/production_execution_group_panel.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

// 进行中外层（按分析批次聚合）直接报工：外层多选 → 批量报工；
// 行内「报工 N 项」按钮直报；跨车间混合给出明确警告且不跳转。
void main() {
  testWidgets('outer batch report merges reportable work orders', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = _router();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue(const {
            Perm.productionExecutionView,
            Perm.productionDailyReportView,
            Perm.productionDailyReportCreate,
          }),
          productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
            _repository(),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await _selectGroup(tester, '联合分析 SO-1 / SO-2');
    await _selectGroup(tester, '分析 SO-3');
    await tester.tap(
      find.byKey(const ValueKey('execution-group-batch-report')),
    );
    await tester.pumpAndSettle();

    expect(find.text('批量来源 segment-a,segment-b'), findsOneWidget);
  });

  testWidgets('row action reports a single group directly', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = _router();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue(const {
            Perm.productionExecutionView,
            Perm.productionDailyReportView,
            Perm.productionDailyReportCreate,
          }),
          productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
            _repository(),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('报工 1 项').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('报工 1 项').first);
    await tester.pumpAndSettle();

    expect(find.text('单项来源 segment-a'), findsOneWidget);
  });

  testWidgets('mixed workshops across groups warn and stay put', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = _router();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue(const {
            Perm.productionExecutionView,
            Perm.productionDailyReportView,
            Perm.productionDailyReportCreate,
          }),
          productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
            _repository(mixedWorkshops: true),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await _selectGroup(tester, '联合分析 SO-1 / SO-2');
    await _selectGroup(tester, '分析 SO-3');
    await tester.tap(
      find.byKey(const ValueKey('execution-group-batch-report')),
    );
    await tester.pumpAndSettle();

    // 全局通知宿主不在测试路由内，按行为断言：跨车间混合不跳转、面板仍在。
    expect(find.text('批量来源'), findsNothing);
    expect(find.text('单项来源'), findsNothing);
    expect(find.text('联合分析 SO-1 / SO-2'), findsOneWidget);
  });
}

GoRouter _router() => GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (_, _) =>
          const Scaffold(body: ProductionExecutionGroupPanel(keyword: '')),
    ),
    GoRoute(
      path: '/production/daily-reports/new',
      builder: (_, state) {
        final single = state.uri.queryParameters['executionSegmentId'];
        final batch = state.uri.queryParameters['executionSegmentIds'];
        return Scaffold(
          body: Text(single != null ? '单项来源 $single' : '批量来源 ${batch ?? ''}'),
        );
      },
    ),
    GoRoute(
      path: '/production/plans/:id',
      builder: (_, state) =>
          Scaffold(body: Text('计划 ${state.pathParameters['id']}')),
    ),
  ],
);

ProductionExecutionWorkbenchRepository _repository({
  bool mixedWorkshops = false,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        final data = switch (request.path) {
          '/production/execution-workbench' => {
            'items': [
              _group('analysis-1', '联合分析 SO-1 / SO-2', 1),
              _group('analysis-2', '分析 SO-3', 1),
            ],
            'page': 1,
            'size': 50,
            'total': 2,
            'totalPages': 1,
          },
          '/production/execution-workbench/ANALYSIS/analysis-1/work-orders' => {
            'items': [_task('segment-a', '产品 A', 'READY')],
            'page': 1,
            'size': 50,
            'total': 1,
            'totalPages': 1,
          },
          '/production/execution-workbench/ANALYSIS/analysis-2/work-orders' => {
            'items': [
              _task(
                'segment-b',
                '产品 B',
                'IN_PROGRESS',
                workshopId: mixedWorkshops ? 'workshop-2' : 'workshop-1',
                workshopName: mixedWorkshops ? '装配二车间' : '装配一车间',
              ),
            ],
            'page': 1,
            'size': 50,
            'total': 1,
            'totalPages': 1,
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
  return ProductionExecutionWorkbenchRepository(ApiClient(dio));
}

Map<String, dynamic> _group(String id, String label, int reportableCount) => {
  'rootType': 'ANALYSIS',
  'rootId': id,
  'rootLabel': label,
  'status': 'PREPARED',
  'reportableCount': reportableCount,
  'planCount': 1,
  'segmentCount': 1,
};

Map<String, dynamic> _task(
  String id,
  String product,
  String status, {
  String workshopId = 'workshop-1',
  String workshopName = '装配一车间',
}) => {
  'segmentId': id,
  'planId': 'plan-$id',
  'planNo': 'SJ-$id',
  'segmentCode': 'GD-$id',
  'salesOrderNos': 'SO-001',
  'workshopDepartmentId': workshopId,
  'workshopName': workshopName,
  'responsibleEmployeeName': '负责人',
  'productCode': 'P-$id',
  'productName': product,
  'productColorName': '本色',
  'productUnitName': '件',
  'plannedQty': 10,
  'reportedQty': status == 'IN_PROGRESS' ? 2 : 0,
  'segmentStatus': status,
  'materialStatus': 'KIT_READY',
  'preparationStatus': 'PREPARED',
  'issued': true,
  'canReport': true,
  'canBatchReport': true,
  'lockVersion': 1,
};

Future<void> _selectGroup(WidgetTester tester, String label) async {
  final row = find
      .ancestor(of: find.text(label), matching: find.byType(Row))
      .first;
  final checkbox = find
      .descendant(of: row, matching: find.byType(Checkbox))
      .first;
  await tester.tap(checkbox, warnIfMissed: false);
  await tester.pump();
}
