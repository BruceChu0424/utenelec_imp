import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_page.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';
import 'package:uten_imp/features/department/widgets/uten_department_picker.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
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

      await tester.scrollUntilVisible(
        find.text('涉及 2 条路径 · 展开路径'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('涉及 2 条路径 · 展开路径'), findsOneWidget);
      expect(find.text('建议：采购'), findsOneWidget);
      expect(find.text('确认路线（0）'), findsOneWidget);
      final dropdown = tester
          .widget<DropdownButtonFormField<MaterialSupplyRoute>>(
            find.byType(DropdownButtonFormField<MaterialSupplyRoute>),
          );
      expect(dropdown.initialValue, isNull);

      final routeFinder = find.byType(
        DropdownButtonFormField<MaterialSupplyRoute>,
      );
      await tester.ensureVisible(routeFinder);
      await tester.pumpAndSettle();
      await tester.tap(routeFinder);
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

      expect(find.text('填写生产计划单（0）'), findsOneWidget);
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
      expect(find.textContaining('采购和委外后代只作依赖提示'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byType(DropdownButtonFormField<MaterialSupplyRoute>),
        300,
        scrollable: find.byType(Scrollable).first,
      );
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

  testWidgets(
    'route rows support tri-state selection, deep-green state and subset notify',
    (tester) async {
      final harness = await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisNotify,
        },
        analysisJson: _buySelectionAnalysisJson(),
      );

      final header = find.byKey(
        const ValueKey('material-route-select-all-BUY'),
      );
      await tester.scrollUntilVisible(
        header,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await Scrollable.ensureVisible(tester.element(header), alignment: 0.5);
      await tester.pump();
      expect(tester.widget<Checkbox>(header).value, isFalse);

      await tester.tap(header);
      await tester.pump();
      expect(tester.widget<Checkbox>(header).value, isTrue);
      expect(find.text('提交采购需求并通知采购（2）'), findsOneWidget);

      final first = find.byKey(
        const ValueKey('material-select-ACTION|buy-action-1'),
      );
      await tester.tap(first);
      await tester.pump();
      expect(tester.widget<Checkbox>(header).value, isNull);
      expect(find.text('提交采购需求并通知采购（1）'), findsOneWidget);

      final selectedRow = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('material-row-ACTION|buy-action-2')),
      );
      expect(
        (selectedRow.decoration as BoxDecoration).color,
        UtenColors.deepGreen,
      );

      final subcontract = find.byKey(
        const ValueKey('material-select-ACTION|subcontract-action-1'),
      );
      await tester.ensureVisible(subcontract);
      await tester.pump();
      await tester.tap(subcontract);
      await tester.pump();
      expect(tester.widget<Checkbox>(subcontract).value, isTrue);

      final buyNotify = find.text('提交采购需求并通知采购（1）');
      await tester.ensureVisible(buyNotify);
      await tester.pump();
      await tester.tap(buyNotify);
      await tester.pumpAndSettle();
      final request = harness.requests.singleWhere(
        (request) => request.path.endsWith('/notify'),
      );
      expect(request.data, {
        'version': 3,
        'fingerprint': 'a' * 64,
        'idempotencyKey': isA<String>(),
        'target': 'BUY',
        'actionGroupKeys': ['buy-action-2'],
      });
      expect(tester.widget<Checkbox>(header).value, isFalse);
      expect(tester.widget<Checkbox>(subcontract).value, isTrue);
    },
  );

  testWidgets(
    'MAKE section renders parent-child BOM and links duplicate action groups',
    (tester) async {
      await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisNotify,
        },
        analysisJson: _makeTreeAnalysisJson(),
      );

      final tree = find.byKey(const Key('material-bom-tree'));
      await tester.scrollUntilVisible(
        tree,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.byKey(const ValueKey('material-bom-product-product-line-1')),
        findsOneWidget,
      );
      expect(find.textContaining('装配'), findsWidgets);
      expect(find.textContaining('· 发货参考'), findsWidgets);
      expect(find.text('采购依赖'), findsOneWidget);

      final first = find.byKey(
        const ValueKey('material-bom-select-make-path-1'),
      );
      final linked = find.byKey(
        const ValueKey('material-bom-select-make-path-2'),
      );
      await tester.tap(first);
      await tester.pump();
      expect(tester.widget<Checkbox>(first).value, isTrue);
      expect(tester.widget<Checkbox>(linked).value, isTrue);
      expect(
        tester
            .getTopLeft(
              find.byKey(const ValueKey('material-bom-node-node-make-1')),
            )
            .dy,
        lessThan(
          tester
              .getTopLeft(
                find.byKey(const ValueKey('material-bom-node-node-buy-child')),
              )
              .dy,
        ),
      );
    },
  );

  testWidgets(
    'selected product uses wizard fields, submits only for approval and resets next batch',
    (tester) async {
      final firstRound = _analysisJson(const ['PLAN_PREVIEW', 'GENERATE_PLAN']);
      final firstRoundProducts = firstRound['products']! as List<dynamic>;
      (firstRoundProducts.first as Map<String, dynamic>)
        ..['readyStartQty'] = 6
        ..['readyFinishQty'] = 4
        ..['readyShipQty'] = 2;
      final secondRound = _analysisJson(const [
        'PLAN_PREVIEW',
        'GENERATE_PLAN',
      ]);
      final products = secondRound['products']! as List<dynamic>;
      (products.first as Map<String, dynamic>)
        ..['readyNowQty'] = 1
        ..['readyFinishQty'] = 1;
      final harness = await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisGenerate,
        },
        analysisJson: firstRound,
        billDate: '2026-08-09',
        deliveryDate: '2026-08-12',
        departmentId: 'workshop-1',
        workshopName: '装配一车间',
        workerId: 'worker-1',
        responseOverride: (request) {
          if (request.path.endsWith('/plan-preview')) {
            return {
              'analysisId': 'analysis-1',
              'version': 3,
              'fingerprint': 'a' * 64,
              'previewFingerprint': 'c' * 64,
              'warehouseId': 'warehouse-1',
              'allReady': true,
              'allowedActions': ['GENERATE_PLAN'],
              'items': [
                {
                  'analysisLineId': 'product-line-1',
                  'requestedQty': 10,
                  'readyNowQty': 4,
                  'selectedQty': 3,
                  'canGenerate': true,
                },
              ],
            };
          }
          if (request.path.endsWith('/generate-plan')) {
            return {'analysis': secondRound, 'plans': <Map<String, dynamic>>[]};
          }
          return null;
        },
      );

      final firstProductCard = find.byKey(
        const ValueKey('material-analysis-product-product-line-1'),
      );
      expect(
        find.descendant(
          of: firstProductCard,
          matching: find.text('可开工（分析参考） 6'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: firstProductCard, matching: find.text('可完工入库 4')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: firstProductCard,
          matching: find.text('预计可发货（参考） 2'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: firstProductCard,
          matching: find.byTooltip(
            '仅用于分析物料准备进度；正式计划仍按可完工量保守下达，'
            'START/ASSEMBLY/FINISH 按一次齐套计算，不能单独按可开工量下达。',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: firstProductCard,
          matching: find.byTooltip(
            '仅供分析参考，不预留包材、不阻止实际发货；'
            '实际发货仍以成品入库和销售预留为准。',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: firstProductCard,
          matching: find.textContaining('FINISH + PER_PACKAGE/FIXED_BATCH'),
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(
          const ValueKey('material-analysis-product-select-product-line-1'),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('batch-qty-product-line-1')),
        '3',
      );
      await tester.tap(find.text('填写生产计划单（1）'));
      await tester.pumpAndSettle();
      expect(find.text('生产计划单'), findsWidgets);

      await tester.tap(find.text('汇总确认'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('production-plan-wizard-submit')));
      await tester.pumpAndSettle();

      final generate = harness.requests.singleWhere(
        (request) => request.path.endsWith('/generate-plan'),
      );
      final body = generate.data! as Map<String, dynamic>;
      expect(body['approveNow'], isFalse);
      expect(body['departmentId'], 'workshop-1');
      expect(body['workerId'], 'worker-1');
      expect(body['items'], [
        {
          'analysisLineId': 'product-line-1',
          'qty': 3.0,
          'billDate': '2026-08-09',
          'deliveryDate': '2026-08-12',
          'departmentId': 'workshop-1',
          'workshopName': '装配一车间',
          'workerId': 'worker-1',
        },
      ]);
      final quantityField = tester.widget<TextField>(
        find.byKey(const Key('batch-qty-product-line-1')),
      );
      expect(quantityField.controller?.text, '1');
      expect(find.text('填写生产计划单（0）'), findsOneWidget);
    },
  );
}

Future<void> _chooseRoute(WidgetTester tester, String label) async {
  final routeFinder = find.byType(DropdownButtonFormField<MaterialSupplyRoute>);
  if (routeFinder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      routeFinder,
      300,
      scrollable: find.byType(Scrollable).first,
    );
  } else {
    await tester.ensureVisible(routeFinder);
  }
  await tester.pumpAndSettle();
  await tester.tap(routeFinder);
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
  Map<String, dynamic>? analysisJson,
  Map<String, dynamic>? Function(RequestOptions request)? responseOverride,
  String? billDate,
  String? deliveryDate,
  String? departmentId,
  String? workshopName,
  String? workerId,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final requests = <RequestOptions>[];
  final api = _api(
    requests,
    allowedActions,
    analysisJson: analysisJson,
    responseOverride: responseOverride,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        productionPlanRepositoryProvider.overrideWithValue(
          ProductionPlanRepository(api),
        ),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        departmentPickerTreeProvider.overrideWith(
          (ref) async => const <DepartmentNode>[],
        ),
        currentPermissionsProvider.overrideWithValue(permissions),
      ],
      child: MaterialApp(
        home: ProductionMaterialAnalysisPage(
          seed: ProductionMaterialAnalysisSeed(
            analysisId: analysisId,
            warehouseId: 'warehouse-1',
            billDate: billDate,
            deliveryDate: deliveryDate,
            departmentId: departmentId,
            workshopName: workshopName,
            workerId: workerId,
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

ApiClient _api(
  List<RequestOptions> requests,
  List<String> allowedActions, {
  Map<String, dynamic>? analysisJson,
  Map<String, dynamic>? Function(RequestOptions request)? responseOverride,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        requests.add(request);
        final custom = responseOverride?.call(request);
        final data =
            custom ??
            switch (request.path) {
              '/master/warehouses/dict' => [
                {'id': 'warehouse-1', 'name': '主仓'},
              ],
              '/production/material-analyses/preview' =>
                analysisJson ?? _analysisJson(allowedActions),
              '/production/material-analyses/analysis-1' =>
                analysisJson ?? _analysisJson(allowedActions),
              '/production/material-analyses/sales-candidates' => {
                'items': <Map<String, dynamic>>[],
                'page': 1,
                'size': 20,
                'total': 0,
                'totalPages': 1,
              },
              '/production/material-analyses/analysis-1/routes' =>
                _analysisJson(allowedActions, routeConfirmed: true),
              '/production/material-analyses/analysis-1/notify' =>
                analysisJson ?? _analysisJson(allowedActions),
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

Map<String, dynamic> _buySelectionAnalysisJson() {
  final json = _analysisJson(const ['PLAN_PREVIEW', 'GENERATE_PLAN']);
  json['flatMaterials'] = [
    _routeMaterial(
      id: 'buy-line-1',
      nodeKey: 'buy-node-1',
      actionGroupKey: 'buy-action-1',
      goodsCode: 'BUY-1',
      goodsName: '采购件一',
      route: 'BUY',
      controlStage: 'START',
    ),
    _routeMaterial(
      id: 'buy-line-2',
      nodeKey: 'buy-node-2',
      actionGroupKey: 'buy-action-2',
      goodsCode: 'BUY-2',
      goodsName: '采购件二',
      route: 'BUY',
      controlStage: 'FINISH',
    ),
    _routeMaterial(
      id: 'subcontract-line-1',
      nodeKey: 'subcontract-node-1',
      actionGroupKey: 'subcontract-action-1',
      goodsCode: 'SUB-1',
      goodsName: '委外件一',
      route: 'SUBCONTRACT',
      controlStage: 'ASSEMBLY',
    ),
  ];
  return json;
}

Map<String, dynamic> _makeTreeAnalysisJson() {
  final json = _analysisJson(const ['PLAN_PREVIEW', 'GENERATE_PLAN']);
  json['flatMaterials'] = [
    _routeMaterial(
      id: 'make-path-1',
      nodeKey: 'node-make-1',
      actionGroupKey: 'make-shared',
      goodsCode: 'MAKE-A',
      goodsName: '自制组件 A',
      route: 'MAKE',
      controlStage: 'ASSEMBLY',
    ),
    {
      ..._routeMaterial(
        id: 'buy-child',
        nodeKey: 'node-buy-child',
        actionGroupKey: 'buy-child-action',
        goodsCode: 'BUY-CHILD',
        goodsName: '外箱依赖',
        route: 'BUY',
        controlStage: 'SHIP',
      ),
      'parentNodeKey': 'node-make-1',
      'level': 2,
      'actionable': false,
    },
    _routeMaterial(
      id: 'make-path-2',
      nodeKey: 'node-make-2',
      actionGroupKey: 'make-shared',
      goodsCode: 'MAKE-B',
      goodsName: '自制组件 A（另一 BOM 路径）',
      route: 'MAKE',
      controlStage: 'ASSEMBLY',
    ),
  ];
  return json;
}

Map<String, dynamic> _routeMaterial({
  required String id,
  required String nodeKey,
  required String actionGroupKey,
  required String goodsCode,
  required String goodsName,
  required String route,
  required String controlStage,
}) => {
  'materialLineId': id,
  'analysisLineId': 'product-line-1',
  'nodeKey': nodeKey,
  'actionGroupKey': actionGroupKey,
  'materialKey': '$goodsCode||unit-1',
  'goodsId': 'goods-$id',
  'goodsCode': goodsCode,
  'goodsName': goodsName,
  'unitName': '个',
  'level': 1,
  'path': ['测试产品', goodsName],
  'requiredQty': 10,
  'availableQty': 2,
  'shortageQty': 8,
  'sourceSuggestion': route,
  'sourceConfirmed': route,
  'routeConfirmed': true,
  'controlStage': controlStage,
  'hardGate': true,
  'actionable': true,
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
