import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_history_page.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  test(
    'subcontract preparation notification route carries stable plan item id',
    () {
      expect(
        RoutePath.productionSubcontractPreparations(planItemId: 'plan-item-1'),
        '/subcontract/preparations?planItemId=plan-item-1',
      );
    },
  );

  testWidgets(
    'desktop history exposes server facts and resumes by analysis id',
    (tester) async {
      final requests = <RequestOptions>[];
      final api = _api(requests);
      final router = GoRouter(
        initialLocation: RouteName.productionMaterialAnalysisHistory,
        routes: [
          GoRoute(
            path: RouteName.productionMaterialAnalysisHistory,
            builder: (_, _) => const ProductionMaterialAnalysisHistoryPage(
              initialSection: 'subcontract-preparations',
            ),
          ),
          GoRoute(
            path: RouteName.productionMaterialAnalysis,
            builder: (_, state) {
              final seed = state.extra! as ProductionMaterialAnalysisSeed;
              return Scaffold(body: Text('resume-${seed.analysisId}'));
            },
          ),
          GoRoute(
            path: RouteName.productionPlanList,
            builder: (_, _) => const Scaffold(body: Text('plan-history')),
          ),
        ],
      );
      addTearDown(router.dispose);

      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            productionPlanRepositoryProvider.overrideWithValue(
              ProductionPlanRepository(api),
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('subcontract-preparation-task-list')),
        findsOneWidget,
      );
      await tester.tap(find.text('分析记录'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('analysis-history-table')), findsOneWidget);
      expect(find.text('部分已下达，剩余待料'), findsWidgets);
      expect(find.textContaining('返工、委外前置自制'), findsOneWidget);
      expect(find.textContaining('RW-20260808-001'), findsOneWidget);
      expect(find.text('生产调度员'), findsOneWidget);
      expect(find.text('12 / 30'), findsOneWidget);
      expect(find.text('继续处理 →'), findsOneWidget);
      expect(
        requests.map((request) => request.path),
        containsAllInOrder([
          '/production/material-analyses/subcontract-preparations',
          '/production/material-analyses',
        ]),
      );

      // 新交互契约：单击只选中，双击才打开（resume）。
      await tester.tap(find.textContaining('RW-20260808-001'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.textContaining('RW-20260808-001'));
      await tester.pumpAndSettle();
      expect(find.text('resume-analysis-1'), findsOneWidget);
    },
  );

  testWidgets('375dp preparation queue shows state, blocker and 48dp action', (
    tester,
  ) async {
    final requests = <RequestOptions>[];
    final api = _api(requests);
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue(const {
            Perm.productionMaterialAnalysisView,
            Perm.productionMaterialAnalysisCreate,
          }),
          productionPlanRepositoryProvider.overrideWithValue(
            ProductionPlanRepository(api),
          ),
        ],
        child: const MaterialApp(
          home: ProductionMaterialAnalysisHistoryPage(
            initialSection: 'subcontract-preparations',
            planItemId: 'plan-item-1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('subcontract-preparation-task-list')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('analysis-history-table')), findsNothing);
    expect(find.text('待开始物料分析'), findsOneWidget);
    expect(find.text('开始物料分析'), findsOneWidget);
    expect(find.textContaining('分析仓库 主仓'), findsOneWidget);
    expect(
      tester
          .getSize(
            find.byKey(const Key('subcontract-preparation-task-plan-item-1')),
          )
          .height,
      greaterThanOrEqualTo(48),
    );
    expect(tester.takeException(), isNull);
    expect(requests.single.queryParameters['planItemId'], 'plan-item-1');
  });

  testWidgets(
    'starts preparation with server CAS and opens returned analysis',
    (tester) async {
      final requests = <RequestOptions>[];
      final api = _api(requests);
      final router = GoRouter(
        initialLocation: RouteName.productionMaterialAnalysisHistory,
        routes: [
          GoRoute(
            path: RouteName.productionMaterialAnalysisHistory,
            builder: (_, _) => const ProductionMaterialAnalysisHistoryPage(
              initialSection: 'subcontract-preparations',
            ),
          ),
          GoRoute(
            path: RouteName.productionMaterialAnalysis,
            builder: (_, state) {
              final seed = state.extra! as ProductionMaterialAnalysisSeed;
              return Scaffold(body: Text('resume-${seed.analysisId}'));
            },
          ),
          GoRoute(
            path: RouteName.productionPlanList,
            builder: (_, _) => const Scaffold(body: Text('plan-history')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentPermissionsProvider.overrideWithValue(const {
              Perm.productionMaterialAnalysisView,
              Perm.productionMaterialAnalysisCreate,
            }),
            productionPlanRepositoryProvider.overrideWithValue(
              ProductionPlanRepository(api),
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('subcontract-preparation-start-plan-item-1')),
      );
      await tester.pumpAndSettle();

      expect(find.text('resume-analysis-started'), findsOneWidget);
      final start = requests.singleWhere(
        (request) => request.path.endsWith('/plan-item-1/start'),
      );
      final body = (start.data as Map).cast<String, dynamic>();
      expect(body['expectedVersion'], 3);
      expect(body['warehouseId'], 'warehouse-1');
      expect(
        body['idempotencyKey'],
        startsWith('subcontract-preparation-start-'),
      );
    },
  );
}

ApiClient _api(List<RequestOptions> requests) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        requests.add(request);
        if (request.path.endsWith('/subcontract-preparations')) {
          handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              statusCode: 200,
              data: _preparationPage(),
            ),
          );
          return;
        }
        if (request.path.endsWith('/plan-item-1/start')) {
          handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              statusCode: 200,
              data: {
                'planItemId': 'plan-item-1',
                'status': 'IN_PREPARATION',
                'analysisId': 'analysis-started',
                'analysisItemId': 'analysis-item-started',
                'version': 4,
              },
            ),
          );
          return;
        }
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: _analysisPage(),
          ),
        );
      },
    ),
  );
  return ApiClient(dio);
}

Map<String, dynamic> _preparationPage() => {
  'items': [
    {
      'planItemId': 'plan-item-1',
      'orderId': 'order-1',
      'orderItemId': 'order-item-1',
      'orderBillNo': 'WW-2026-001',
      'targetGoodsId': 'goods-1',
      'targetGoodsCode': 'WIP-001',
      'targetGoodsName': '待电镀装配件',
      'unitId': 'unit-1',
      'unitName': '件',
      'requiredQty': 100,
      'preparedQty': 0,
      'issuedQty': 0,
      'needDate': '2026-09-05',
      'status': 'ACTION_REQUIRED',
      'preparationWarehouseId': 'warehouse-1',
      'preparationWarehouseName': '主仓',
      'warehouseSelectionRequired': false,
      'allowedActions': ['START_PREPARATION'],
      'version': 3,
      'updatedAt': '2026-08-30T03:00:00Z',
    },
  ],
  'page': 1,
  'size': 20,
  'total': 1,
  'totalPages': 1,
};

Map<String, dynamic> _analysisPage() => {
  'items': [
    {
      'analysisId': 'analysis-1',
      'status': 'PARTIALLY_PLANNED',
      'version': 8,
      'fingerprint': 'a' * 64,
      'warehouseId': 'warehouse-1',
      'warehouseCode': 'WH-01',
      'warehouseName': '主仓',
      'analyzedAt': '2026-08-08T02:00:00Z',
      'updatedAt': '2026-08-08T03:00:00Z',
      'makerId': 'employee-1',
      'makerName': '生产调度员',
      'sourceCount': 1,
      'sourceTypes': ['REWORK', 'SUBCONTRACT_PREPARATION'],
      'sourceRefs': ['RW-20260808-001'],
      'productLabels': ['P-001 返工产品'],
      'requestedQty': 100,
      'submittedQty': 10,
      'approvedQty': 5,
      'remainingQty': 85,
      'readyNowQty': 12,
      'readyByDateQty': 30,
    },
  ],
  'page': 1,
  'size': 20,
  'total': 1,
  'totalPages': 1,
};
