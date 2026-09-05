import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/pages/production_board_page.dart';
import 'package:uten_imp/features/production/repositories/production_execution_workbench_repository.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets('production board child-plan row opens the child plan', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var progressReads = 0;
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const ProductionBoardPage(initialTab: 1),
        ),
        GoRoute(
          path: '/production/plans/:id',
          builder: (context, state) => Scaffold(
            body: Column(
              children: [
                Text('已打开计划 ${state.pathParameters['id']}'),
                FilledButton(
                  onPressed: () => context.pop(),
                  child: const Text('返回进度看板'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          productionPlanRepositoryProvider.overrideWithValue(_repository()),
          productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
            _workbenchRepository(
              onRead: () => progressReads++,
              reportable: true,
            ),
          ),
          currentPermissionsProvider.overrideWithValue(const <String>{}),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('联合分析 SO-A / SO-B'), findsOneWidget);
    expect(find.text('SEG-PARENT / SEG-CHILD'), findsOneWidget);
    await _doubleTapRow(tester, find.text('联合分析 SO-A / SO-B'));
    await tester.pumpAndSettle();
    expect(find.text('工单与进度'), findsOneWidget);
    expect(find.text('SEG-CHILD'), findsOneWidget);
    final parentRow = find
        .ancestor(of: find.text('父产品'), matching: find.byType(Row))
        .first;
    expect(
      find.descendant(of: parentRow, matching: find.byType(Checkbox)),
      findsNothing,
    );
    expect(find.textContaining('批量报工('), findsNothing);
    await _doubleTapRow(tester, find.text('SEG-CHILD'));
    await tester.pumpAndSettle();

    expect(find.text('已打开计划 child-plan-1'), findsOneWidget);
    final readsBeforeReturn = progressReads;
    await tester.tap(find.text('返回进度看板'));
    await tester.pumpAndSettle();
    expect(progressReads, greaterThan(readsBeforeReturn));
  });

  testWidgets('compact board child-plan stays usable at 1.3 text scale', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    // 页面级容器为唯一 gutter（面板内层容器已移除），375px 紧凑布局回归验证。
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const ProductionBoardPage(initialTab: 1),
        ),
        GoRoute(
          path: '/production/plans/:id',
          builder: (context, state) =>
              Scaffold(body: Text('已打开计划 ${state.pathParameters['id']}')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          productionPlanRepositoryProvider.overrideWithValue(_repository()),
          productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
            _workbenchRepository(),
          ),
          currentPermissionsProvider.overrideWithValue(const <String>{}),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final root = find.text('联合分析 SO-A / SO-B');
    await tester.ensureVisible(root);
    expect(root.hitTestable(), findsOneWidget);
    await _doubleTapRow(tester, root);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    expect(find.text('SEG-CHILD'), findsOneWidget);
    expect(find.text('物料不齐套 · 备料中'), findsWidgets);
    // Compact tables keep the status columns fixed at the left edge while the
    // work-order number may be horizontally off-screen. Double-click the exact
    // WAITING status cell to exercise the same row-open contract.
    await _doubleTapRow(tester, find.text('待料'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('已打开计划 child-plan-1'), findsOneWidget);
  });

  testWidgets('ongoing analysis detail supports direct batch reporting', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const ProductionBoardPage(initialTab: 1),
        ),
        GoRoute(
          path: '/production/daily-reports/new',
          builder: (_, state) => Scaffold(
            body: Text(
              '批量报工 ${state.uri.queryParameters['executionSegmentId'] ?? state.uri.queryParameters['executionSegmentIds']}',
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          productionPlanRepositoryProvider.overrideWithValue(_repository()),
          productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
            _workbenchRepository(reportable: true),
          ),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.productionExecutionView,
            Perm.productionDailyReportView,
            Perm.productionDailyReportCreate,
          }),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await _doubleTapRow(tester, find.text('联合分析 SO-A / SO-B'));
    await tester.pumpAndSettle();

    final parentRow = find
        .ancestor(of: find.text('父产品'), matching: find.byType(Row))
        .first;
    final checkbox = find
        .descendant(of: parentRow, matching: find.byType(Checkbox))
        .first;
    await tester.tap(checkbox);
    await tester.pump();
    await tester.tap(find.text('批量报工(1)'));
    await tester.pumpAndSettle();

    expect(find.text('批量报工 segment-parent'), findsOneWidget);
  });
}

Future<void> _doubleTapRow(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(finder);
  await tester.pump();
}

ProductionPlanRepository _repository({VoidCallback? onProgressRead}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        if (request.path == '/production/plans/progress') {
          onProgressRead?.call();
        }
        final data = switch (request.path) {
          '/production/plans/progress/summary' => {
            'count': 1,
            'sumQty': 10,
            'sumInbound': 0,
          },
          '/production/plans/progress/workshops' => <Map<String, dynamic>>[],
          '/production/plans/progress' => {
            'items': [
              {
                'planId': 'parent-plan-1',
                'billNo': 'SJ-PARENT',
                'lineCount': 1,
                'totalQty': 10,
                'inboundQty': 0,
                'materialState': 'PARTIAL',
                'materialSegmentCount': 2,
                'materialReadySegmentCount': 1,
                'materialTotalQty': 10,
                'materialReadyQty': 6,
                'materialPercent': 0.6,
                'canStartNow': true,
                'percent': 0,
                'closed': false,
                'subplans': [
                  {
                    'planId': 'child-plan-1',
                    'billNo': 'SJ-CHILD',
                    'status': 1,
                    'closed': false,
                    'totalQty': 5,
                    'reportedQty': 2,
                    'inboundQty': 1,
                    'materialState': 'WAITING',
                    'materialSegmentCount': 1,
                    'materialReadySegmentCount': 0,
                    'materialTotalQty': 5,
                    'materialReadyQty': 0,
                    'materialPercent': 0,
                    'canStartNow': false,
                    'percent': 0,
                  },
                ],
              },
            ],
            'page': 1,
            'size': 20,
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
  return ProductionPlanRepository(ApiClient(dio));
}

ProductionExecutionWorkbenchRepository _workbenchRepository({
  VoidCallback? onRead,
  bool reportable = false,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        onRead?.call();
        final data = switch (request.path) {
          '/production/execution-workbench' => {
            'items': [_workbenchRootJson()],
            'page': 1,
            'size': 50,
            'total': 1,
            'totalPages': 1,
          },
          '/production/execution-workbench/ANALYSIS/analysis-root-1/work-orders' =>
            {
              'items': [
                _workOrderJson(
                  segmentId: 'segment-parent',
                  planId: 'parent-plan-1',
                  planNo: 'SJ-PARENT',
                  segmentCode: 'SEG-PARENT',
                  productName: '父产品',
                  materialReady: true,
                  canReport: reportable,
                ),
                _workOrderJson(
                  segmentId: 'segment-child',
                  planId: 'child-plan-1',
                  planNo: 'SJ-CHILD',
                  segmentCode: 'SEG-CHILD',
                  productName: '自制子件',
                  materialReady: false,
                ),
              ],
              'page': 1,
              'size': 30,
              'total': 2,
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

Map<String, dynamic> _workbenchRootJson() => {
  'rootType': 'ANALYSIS',
  'rootId': 'analysis-root-1',
  'rootLabel': '联合分析 SO-A / SO-B',
  'status': 'PREPARING',
  'salesOrderPreview': 'SO-A / SO-B',
  'salesOrderCount': 2,
  'workOrderPreview': 'SEG-PARENT / SEG-CHILD',
  'workOrderCount': 2,
  'workshopPreview': '装配一车间',
  'workshopCount': 1,
  'productCodePreview': 'P-001 / C-001',
  'productNamePreview': '父产品 / 自制子件',
  'productColorPreview': '本色',
  'productCount': 2,
  'quantitySummary': '件: 计划 15 / 报工 2 / 实收 1',
  'executionUnitCount': 1,
  'planCount': 2,
  'segmentCount': 2,
  'waitingCount': 1,
  'readyCount': 1,
};

Map<String, dynamic> _workOrderJson({
  required String segmentId,
  required String planId,
  required String planNo,
  required String segmentCode,
  required String productName,
  required bool materialReady,
  bool canReport = false,
}) => {
  'segmentId': segmentId,
  'planId': planId,
  'planNo': planNo,
  'segmentCode': segmentCode,
  'salesOrderNos': 'SO-A',
  'workshopDepartmentId': 'workshop-1',
  'workshopName': '装配一车间',
  'responsibleEmployeeName': '车间负责人',
  'productCode': materialReady ? 'P-001' : 'C-001',
  'productName': productName,
  'productColorName': '本色',
  'productUnitName': '件',
  'plannedQty': materialReady ? 10 : 5,
  'reportedQty': materialReady ? 2 : 0,
  'remainingReportQty': materialReady ? 8 : 5,
  'inboundQty': materialReady ? 1 : 0,
  'segmentStatus': materialReady ? 'READY' : 'WAITING',
  'materialStatus': materialReady ? 'KIT_READY' : 'KIT_SHORT',
  'preparationStatus': 'PREPARING',
  'materialReady': materialReady,
  'warehouseReady': materialReady,
  'issued': false,
  'canReport': canReport,
  'canBatchReport': canReport,
  'blockedReason': materialReady ? '仓库尚未完成全部备料出库' : '物料尚未齐套',
  'lockVersion': 1,
};
