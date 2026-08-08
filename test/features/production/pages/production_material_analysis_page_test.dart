import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_page.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

void main() {
  testWidgets('fresh analysis exposes audited manual source types', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      size: const Size(1200, 900),
      permissions: const {Perm.productionMaterialAnalysisManage},
      seeded: false,
    );

    expect(find.text('手工计划（返工 / 试制 / 样品 / 备库）'), findsOneWidget);
    expect(find.text('物料分析记录'), findsOneWidget);
    expect(find.text('生产计划历史'), findsOneWidget);
    expect(find.byKey(const Key('manual-source-ref')), findsOneWidget);
    expect(find.text('同一需求请始终使用同一个编号'), findsOneWidget);
    expect(find.byKey(const Key('manual-source-goods')), findsOneWidget);
    expect(find.byKey(const Key('manual-source-reason')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('manual-source-')));
    await tester.pumpAndSettle();
    expect(find.text('返工'), findsOneWidget);
    expect(find.text('试制'), findsOneWidget);
    expect(find.text('样品'), findsOneWidget);
    expect(find.text('备库'), findsOneWidget);
    expect(find.text('其他'), findsOneWidget);
  });

  testWidgets('seeded manual analysis sends the stable demand reference', (
    tester,
  ) async {
    final harness = await _pumpPage(
      tester,
      size: const Size(1200, 900),
      permissions: const {Perm.productionMaterialAnalysisManage},
      sources: const [
        MaterialAnalysisSourceInput(
          sourceType: 'REWORK',
          sourceRef: 'RW-20260808-001',
          goodsId: 'goods-1',
          unitId: 'unit-1',
          requestedQty: 3,
          sourceReason: '客诉返工',
        ),
      ],
    );

    final request = harness.requests.singleWhere(
      (value) => value.path == '/production/material-analyses/preview',
    );
    expect((request.data as Map<String, dynamic>)['sources'], [
      {
        'sourceType': 'REWORK',
        'sourceRef': 'RW-20260808-001',
        'goodsId': 'goods-1',
        'unitId': 'unit-1',
        'requestedQty': 3.0,
        'sourceReason': '客诉返工',
      },
    ]);
  });

  testWidgets(
    'existing joint analysis loads full detail and never posts a selected source subset',
    (tester) async {
      final harness = await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {Perm.productionMaterialAnalysisManage},
        analysisId: 'analysis-1',
      );

      expect(
        harness.requests.where(
          (request) =>
              request.method == 'GET' &&
              request.path == '/production/material-analyses/analysis-1',
        ),
        hasLength(1),
      );
      expect(
        harness.requests.where(
          (request) =>
              request.method == 'POST' &&
              request.path == '/production/material-analyses/preview',
        ),
        isEmpty,
      );
      expect(find.text('第二测试产品'), findsOneWidget);
    },
  );

  testWidgets(
    'suggested route stays empty until explicit confirmation and paths group once',
    (tester) async {
      final harness = await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisRoute,
          Perm.productionMaterialAnalysisGenerate,
        },
      );

      expect(find.text('涉及 2 条路径 · 展开路径'), findsOneWidget);
      expect(find.text('建议：采购'), findsOneWidget);
      expect(find.text('确认路线（0）'), findsOneWidget);
      final dropdown = tester
          .widget<DropdownButtonFormField<MaterialSupplyRoute>>(
            find.byType(DropdownButtonFormField<MaterialSupplyRoute>),
          );
      expect(dropdown.initialValue, isNull);

      await tester.tap(
        find.byType(DropdownButtonFormField<MaterialSupplyRoute>),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('采购').last);
      await tester.pumpAndSettle();

      expect(find.text('确认路线（1）'), findsOneWidget);
      expect(find.byKey(const Key('material-route-reason')), findsNothing);
      expect(harness.requests.where((r) => r.method == 'PUT'), isEmpty);
    },
  );

  testWidgets(
    'route override requires a reason and cancel keeps empty default',
    (tester) async {
      final harness = await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisRoute,
        },
      );

      await _chooseRoute(tester, '自制');
      expect(find.byKey(const Key('material-route-reason')), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('确认路线（0）'), findsOneWidget);
      expect(
        tester
            .widget<DropdownButtonFormField<MaterialSupplyRoute>>(
              find.byType(DropdownButtonFormField<MaterialSupplyRoute>),
            )
            .initialValue,
        isNull,
      );

      await _chooseRoute(tester, '自制');
      await tester.enterText(
        find.byKey(const Key('material-route-reason')),
        '交期紧急，改为车间自制',
      );
      await tester.tap(find.text('确认路线'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认路线（1）'));
      await tester.pumpAndSettle();

      final routeRequest = harness.requests.singleWhere(
        (request) => request.method == 'PUT',
      );
      expect(routeRequest.data, {
        'version': 3,
        'fingerprint': 'a' * 64,
        'idempotencyKey': isA<String>(),
        'decisions': [
          {
            'actionGroupKey': 'action-fastener',
            'route': 'MAKE',
            'reason': '交期紧急，改为车间自制',
          },
        ],
      });
    },
  );

  testWidgets(
    'forged local approval permission cannot expose server-denied approve action',
    (tester) async {
      await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisGenerate,
          Perm.productionPlanApprove,
          Perm.productionMaterialAnalysisReallocate,
        },
      );

      expect(find.text('生成并提交审批'), findsOneWidget);
      expect(find.text('生成并批准'), findsNothing);
      expect(
        find.byKey(const Key('material-analysis-priority-edit')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'lower-level dependency is informational and exposes no duplicate route control',
    (tester) async {
      await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisRoute,
          Perm.productionMaterialAnalysisNotify,
        },
      );

      await tester.scrollUntilVisible(
        find.byKey(const Key('material-dependency-section')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('由上级自制任务展开'), findsWidgets);
      expect(
        find.byType(DropdownButtonFormField<MaterialSupplyRoute>),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'allocation priority cancel is local and confirm writes the complete CAS order',
    (tester) async {
      final harness = await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisReallocate,
        },
        allowedActions: const ['REALLOCATE'],
      );

      await tester.tap(
        find.byKey(const Key('material-analysis-priority-edit')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('material-analysis-priority-editor')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('material-priority-down-0')),
      );
      await tester.tap(
        find.byKey(const Key('material-analysis-priority-cancel')),
      );
      await tester.pumpAndSettle();
      expect(
        harness.requests.where(
          (request) => request.path.endsWith('/allocation-priorities'),
        ),
        isEmpty,
      );

      await tester.tap(
        find.byKey(const Key('material-analysis-priority-edit')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('material-priority-down-0')),
      );
      await tester.tap(
        find.byKey(const Key('material-analysis-priority-save')),
      );
      await tester.pumpAndSettle();

      final request = harness.requests.singleWhere(
        (request) => request.path.endsWith('/allocation-priorities'),
      );
      expect(request.data, {
        'version': 3,
        'fingerprint': 'a' * 64,
        'idempotencyKey': isA<String>(),
        'items': [
          {'analysisLineId': 'product-line-2', 'priority': 1},
          {'analysisLineId': 'product-line-1', 'priority': 2},
        ],
      });
    },
  );

  testWidgets('compact allocation priority editor stays reachable and usable', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      size: const Size(375, 900),
      permissions: const {
        Perm.productionMaterialAnalysisManage,
        Perm.productionMaterialAnalysisReallocate,
      },
      allowedActions: const ['REALLOCATE'],
    );

    await tester.tap(find.byKey(const Key('material-analysis-priority-edit')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('material-analysis-priority-editor')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('material-priority-down-0')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'compact layout uses cards and keeps grouped path action usable',
    (tester) async {
      await _pumpPage(
        tester,
        size: const Size(375, 900),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisRoute,
        },
      );

      await tester.scrollUntilVisible(
        find.text('涉及 2 条路径 · 展开路径'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('涉及 2 条路径 · 展开路径'), findsOneWidget);
      expect(
        find.ancestor(
          of: find.text('涉及 2 条路径 · 展开路径'),
          matching: find.byType(Card),
        ),
        findsOneWidget,
      );
      await tester.drag(
        find.byKey(const Key('material-analysis-results')),
        const Offset(0, -240),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('涉及 2 条路径 · 展开路径'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.textContaining('测试产品 → 组件 A'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('测试产品 → 组件 A'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _chooseRoute(WidgetTester tester, String label) async {
  await tester.tap(find.byType(DropdownButtonFormField<MaterialSupplyRoute>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<_Harness> _pumpPage(
  WidgetTester tester, {
  required Size size,
  required Set<String> permissions,
  List<String> allowedActions = const ['PLAN_PREVIEW', 'GENERATE_PLAN'],
  bool seeded = true,
  String? analysisId,
  List<MaterialAnalysisSourceInput>? sources,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final requests = <RequestOptions>[];
  final api = _api(requests, allowedActions);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        productionPlanRepositoryProvider.overrideWithValue(
          ProductionPlanRepository(api),
        ),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        currentPermissionsProvider.overrideWithValue(permissions),
      ],
      child: MaterialApp(
        home: ProductionMaterialAnalysisPage(
          seed: ProductionMaterialAnalysisSeed(
            analysisId: analysisId,
            warehouseId: 'warehouse-1',
            sources:
                sources ??
                (seeded
                    ? const [
                        MaterialAnalysisSourceInput(
                          salesOrderItemId: 'sales-line-1',
                          requestedQty: 10,
                        ),
                      ]
                    : const []),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  return _Harness(requests);
}

ApiClient _api(List<RequestOptions> requests, List<String> allowedActions) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        requests.add(request);
        final data = switch (request.path) {
          '/master/warehouses/dict' => [
            {'id': 'warehouse-1', 'name': '主仓'},
          ],
          '/production/material-analyses/preview' => _analysisJson(
            allowedActions,
          ),
          '/production/material-analyses/analysis-1' => _analysisJson(
            allowedActions,
          ),
          '/production/material-analyses/sales-candidates' => {
            'items': <Map<String, dynamic>>[],
            'page': 1,
            'size': 20,
            'total': 0,
            'totalPages': 1,
          },
          '/production/material-analyses/analysis-1/routes' => _analysisJson(
            allowedActions,
            routeConfirmed: true,
          ),
          '/production/material-analyses/analysis-1/allocation-priorities' =>
            _analysisJson(allowedActions),
          _ => <Map<String, dynamic>>[],
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

Map<String, dynamic> _analysisJson(
  List<String> allowedActions, {
  bool routeConfirmed = false,
}) => {
  'analysisId': 'analysis-1',
  'status': 'ANALYZED',
  'version': 3,
  'fingerprint': 'a' * 64,
  'warehouseId': 'warehouse-1',
  'analyzedAt': '2026-08-08T10:00:00Z',
  'allowedActions': allowedActions,
  'products': [
    {
      'analysisLineId': 'product-line-1',
      'salesOrderItemId': 'sales-line-1',
      'orderNo': 'SO-1',
      'goodsCode': 'P-1',
      'goodsName': '测试产品',
      'requestedQty': 10,
      'remainingQty': 10,
      'readyNowQty': 4,
      'readyByDateQty': 8,
      'readinessRatio': 0.4,
      'productionBomPolicy': 'DIRECT_MAKE',
      'missingBom': false,
      'bomOverrideRequired': false,
      'hasActiveBom': false,
      'allocationPriority': 1,
    },
    {
      'analysisLineId': 'product-line-2',
      'sourceType': 'STOCK',
      'goodsCode': 'P-2',
      'goodsName': '第二测试产品',
      'requestedQty': 6,
      'remainingQty': 6,
      'readyNowQty': 2,
      'readyByDateQty': 4,
      'readinessRatio': 0.3333,
      'productionBomPolicy': 'DIRECT_MAKE',
      'missingBom': false,
      'bomOverrideRequired': false,
      'hasActiveBom': false,
      'allocationPriority': 2,
    },
  ],
  'flatMaterials': [
    _materialJson(
      id: 'material-path-1',
      level: 2,
      path: ['测试产品', '组件 A', '共享紧固件'],
      routeConfirmed: routeConfirmed,
    ),
    _materialJson(
      id: 'material-path-2',
      level: 3,
      path: ['测试产品', '组件 B', '下层件', '共享紧固件'],
      routeConfirmed: routeConfirmed,
    ),
    {
      'materialLineId': 'dependency-path-1',
      'analysisLineId': 'product-line-1',
      'nodeKey': 'dependency-node-1',
      'actionGroupKey': 'dependency-action-1',
      'materialKey': 'dependency-goods||unit-1',
      'goodsId': 'dependency-goods',
      'goodsCode': 'D-1',
      'goodsName': '下层依赖件',
      'unitName': '个',
      'level': 3,
      'path': ['测试产品', '自制组件', '下层依赖件'],
      'requiredQty': 20,
      'availableQty': 0,
      'shortageQty': 20,
      'sourceSuggestion': 'BUY',
      'routeConfirmed': false,
      'actionable': false,
    },
  ],
  'warehouses': [
    {'warehouseId': 'warehouse-1', 'warehouseName': '主仓'},
  ],
};

Map<String, dynamic> _materialJson({
  required String id,
  required int level,
  required List<String> path,
  required bool routeConfirmed,
}) => {
  'materialLineId': id,
  'analysisLineId': 'product-line-1',
  'actionGroupKey': 'action-fastener',
  'materialKey': 'goods-fastener||unit-1',
  'goodsId': 'goods-fastener',
  'goodsCode': 'M-1',
  'goodsName': '共享紧固件',
  'unitName': '个',
  'level': level,
  'path': path,
  'requiredQty': 16,
  'availableQty': 3,
  'inboundQty': 2,
  'shortageQty': 11,
  'sourceSuggestion': 'BUY',
  'sourceConfirmed': routeConfirmed ? 'MAKE' : null,
  'routeConfirmed': routeConfirmed,
  'routeReason': routeConfirmed ? '交期紧急，改为车间自制' : null,
  'lowerLevelPending': false,
  'actionable': true,
};

class _Harness {
  const _Harness(this.requests);

  final List<RequestOptions> requests;
}
