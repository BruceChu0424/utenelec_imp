import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_preparation_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  test('stable preparation route carries the plan item id', () {
    expect(
      RoutePath.productionSubcontractPreparations(planItemId: 'plan-item-1'),
      '/subcontract/preparations?planItemId=plan-item-1',
    );
  });

  test('stable preparation route carries the exact source material node', () {
    expect(
      RoutePath.productionSubcontractPreparations(
        sourceAnalysisId: 'analysis-source-1',
        sourceMaterialLineId: 'material-source-1',
      ),
      '/subcontract/preparations?sourceAnalysisId=analysis-source-1&sourceMaterialLineId=material-source-1',
    );
  });

  test(
    'V447 preparation handoff facts parse without client-side inference',
    () {
      final task = SubcontractPreparationTask.fromJson(const {
        'planItemId': 'plan-item-1',
        'orderId': 'order-1',
        'orderItemId': 'order-item-1',
        'status': 'IN_PREPARATION',
        'version': 4,
        'sourceAnalysisId': 'source-analysis-1',
        'sourceMaterialLineId': 'source-material-1',
        'handoffStatus': 'active',
        'takeoverQty': 100,
        'handedOffEntitlementQty': 64,
        'handoffBlocker': '剩余 36 等待原供给到货后自动交接',
      });

      expect(task.sourceAnalysisId, 'source-analysis-1');
      expect(task.sourceMaterialLineId, 'source-material-1');
      expect(task.handoffStatus, 'ACTIVE');
      expect(task.takeoverQty, 100);
      expect(task.handedOffEntitlementQty, 64);
      expect(task.handoffBlocker, contains('自动交接'));
    },
  );

  testWidgets(
    'compact start uses subcontract permission and does not open production without view',
    (tester) async {
      final requests = <RequestOptions>[];
      final api = _api(requests, allowedActions: const ['START_PREPARATION']);
      tester.view.physicalSize = const Size(375, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentPermissionsProvider.overrideWithValue(const {
              Perm.subcontractPreparationView,
              Perm.subcontractPreparationStart,
            }),
            productionPlanRepositoryProvider.overrideWithValue(
              ProductionPlanRepository(api),
            ),
          ],
          child: const MaterialApp(
            home: SubcontractPreparationPage(
              sourceAnalysisId: 'analysis-source-1',
              sourceMaterialLineId: 'material-source-1',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 2026-09-03 分类范式：来源行默认不选（不发请求），先 tap「订货来源」
      // 才加载 /subcontract-preparations 列表（深链参数原样下发）。
      await tester.tap(find.text('订货来源·前置自制'));
      await tester.pumpAndSettle();

      final listRequest = requests.singleWhere(
        (request) =>
            request.path.endsWith('/subcontract-preparations') &&
            request.method == 'GET',
      );
      expect(
        listRequest.queryParameters['sourceAnalysisId'],
        'analysis-source-1',
      );
      expect(
        listRequest.queryParameters['sourceMaterialLineId'],
        'material-source-1',
      );

      expect(
        find.byKey(const Key('subcontract-preparation-compact-list')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('subcontract-preparation-start-plan-item-1')),
      );
      await tester.pumpAndSettle();

      final start = requests.singleWhere(
        (request) => request.path.endsWith('/plan-item-1/start'),
      );
      final body = (start.data as Map).cast<String, dynamic>();
      expect(body['expectedVersion'], 3);
      expect(body['warehouseId'], 'warehouse-1');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop exposes row-specific start menu and no first-task shortcut',
    (tester) async {
      final requests = <RequestOptions>[];
      final api = _api(requests, allowedActions: const ['START_PREPARATION']);
      // 1440 宽：订货来源状态分段行（7 段，无「全部状态」段）在桌面一行排开。
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentPermissionsProvider.overrideWithValue(const {
              Perm.subcontractPreparationView,
              Perm.subcontractPreparationStart,
              Perm.subcontractOrderView,
            }),
            productionPlanRepositoryProvider.overrideWithValue(
              ProductionPlanRepository(api),
            ),
          ],
          child: const MaterialApp(home: SubcontractPreparationPage()),
        ),
      );
      await tester.pumpAndSettle();

      // 来源行默认不选：先 tap「订货来源」再断言桌面表格与行级菜单。
      await tester.tap(find.text('订货来源·前置自制'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('subcontract-preparation-table')),
        findsOneWidget,
      );
      expect(find.text('开始首个待办'), findsNothing);
      await tester.longPress(find.textContaining('WIP-001'));
      await tester.pumpAndSettle();
      expect(find.text('开始前置自制'), findsOneWidget);
      expect(find.text('查看委外订货'), findsOneWidget);
    },
  );

  testWidgets(
    'OPEN_ANALYSIS and production view are both required to deep-link',
    (tester) async {
      final requests = <RequestOptions>[];
      final api = _api(
        requests,
        allowedActions: const ['OPEN_ANALYSIS'],
        status: 'IN_PREPARATION',
        analysisId: 'analysis-1',
      );
      final router = GoRouter(
        initialLocation: RouteName.subcontractPreparations,
        routes: [
          GoRoute(
            path: RouteName.subcontractPreparations,
            builder: (_, _) => const SubcontractPreparationPage(),
          ),
          GoRoute(
            path: RouteName.productionMaterialAnalysis,
            builder: (_, state) {
              final seed = state.extra! as ProductionMaterialAnalysisSeed;
              return Scaffold(body: Text('analysis-${seed.analysisId}'));
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      tester.view.physicalSize = const Size(375, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentPermissionsProvider.overrideWithValue(const {
              Perm.subcontractPreparationView,
              Perm.productionMaterialAnalysisView,
            }),
            productionPlanRepositoryProvider.overrideWithValue(
              ProductionPlanRepository(api),
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      // 来源行默认不选：先 tap「订货来源」加载任务卡，再点「打开物料分析」。
      await tester.tap(find.text('订货来源·前置自制'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('打开物料分析'));
      await tester.pumpAndSettle();
      expect(find.text('analysis-analysis-1'), findsOneWidget);
    },
  );
}

ApiClient _api(
  List<RequestOptions> requests, {
  required List<String> allowedActions,
  String status = 'ACTION_REQUIRED',
  String? analysisId,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        requests.add(request);
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
                'sourceAnalysisId': 'analysis-source-1',
                'sourceMaterialLineId': 'material-source-1',
                'handoffId': 'handoff-1',
                'handoffStatus': 'ACTIVE',
                'takeoverQty': 100,
                'handedOffEntitlementQty': 60,
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
            data: {
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
                  'preparedQty': status == 'ACTION_REQUIRED' ? 0 : 20,
                  'issuedQty': 0,
                  'needDate': '2026-09-05',
                  'status': status,
                  'sourceAnalysisId': 'analysis-source-1',
                  'sourceMaterialLineId': 'material-source-1',
                  'handoffStatus': status == 'ACTION_REQUIRED'
                      ? 'PENDING'
                      : 'ACTIVE',
                  'takeoverQty': status == 'ACTION_REQUIRED' ? 0 : 100,
                  'handedOffEntitlementQty': status == 'ACTION_REQUIRED'
                      ? 0
                      : 60,
                  'analysisId': analysisId,
                  'preparationWarehouseId': 'warehouse-1',
                  'preparationWarehouseName': '主仓',
                  'warehouseSelectionRequired': false,
                  'allowedActions': allowedActions,
                  'version': 3,
                },
              ],
              'page': 1,
              'size': 20,
              'total': 1,
              'totalPages': 1,
            },
          ),
        );
      },
    ),
  );
  return ApiClient(dio);
}
