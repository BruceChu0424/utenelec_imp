import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/production/pages/production_plan_detail_page.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

import '../../../support/document_scope_capability_overrides.dart';

void main() {
  testWidgets(
    'approved direct-make plan skips legacy MRP and shows the execution chain',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final requests = <RequestOptions>[];
      final api = _directMakeApprovedPlanDetailApi(requests);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            productionWriteAllDocumentScope(),
            productionPlanRepositoryProvider.overrideWithValue(
              ProductionPlanRepository(api),
            ),
            masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.productionPlanView,
            }),
          ],
          child: MaterialApp(
            builder: (context, child) => Stack(
              children: [
                child!,
                const Align(
                  alignment: Alignment.topCenter,
                  child: AppNotificationHost(),
                ),
              ],
            ),
            home: const ProductionPlanDetailPage(id: 'plan-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('执行单据与物料台账'), findsOneWidget);
      expect(find.text('执行子计划'), findsOneWidget);
      expect(find.text('零物料 · 无需发料'), findsOneWidget);
      expect(find.textContaining('明细 ('), findsNothing);
      expect(
        find.byKey(const Key('production-plan-draft-product-summary')),
        findsNothing,
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('plan-1|0'))).dy,
        lessThan(
          tester
              .getTopLeft(
                find.byKey(const Key('production-execution-documents-card')),
              )
              .dy,
        ),
      );
      expect(find.text('物料需求只读估算(MRP)'), findsNothing);
      expect(find.textContaining('补建正式计划包'), findsNothing);
      expect(find.textContaining('资料补齐前不能判断齐套'), findsNothing);
      expect(find.textContaining('缺少有效 BOM'), findsNothing);

      final paths = requests.map((request) => request.path).toList();
      expect(paths, isNot(contains('/production/plans/plan-1/mrp')));
      expect(
        paths.where((path) => path.contains('/planning-preview')),
        isEmpty,
      );
      expect(paths.where((path) => path.contains('/planning-draft')), isEmpty);
      expect(
        paths.where((path) => path.contains('/generate-planning-package')),
        isEmpty,
      );

      final openDocuments = find.text('查看执行单据');
      await tester.ensureVisible(openDocuments);
      await tester.tap(openDocuments);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('请从“物料分析准备”生成并审核计划'), findsOneWidget);
      expect(find.textContaining('补建'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'approved plan without segments shows neutral recovery guidance',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _directMakeApprovedPlanDetailApi(
        <RequestOptions>[],
        withSegment: false,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            productionWriteAllDocumentScope(),
            productionPlanRepositoryProvider.overrideWithValue(
              ProductionPlanRepository(api),
            ),
            masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.productionPlanView,
            }),
          ],
          child: const MaterialApp(
            home: ProductionPlanDetailPage(id: 'plan-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('production-execution-segments-empty')),
        findsOneWidget,
      );
      expect(find.textContaining('当前尚未形成执行子计划'), findsOneWidget);
      expect(find.textContaining('物料分析准备'), findsOneWidget);
      expect(find.text('刷新执行状态'), findsOneWidget);
      expect(find.textContaining('补 BOM'), findsNothing);
      expect(find.text('执行单据与物料台账'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'analysis draft returns to analysis, hides generic mutation and keeps approve independent',
    (tester) async {
      final api = _planDetailApi();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            productionWriteAllDocumentScope(),
            productionPlanRepositoryProvider.overrideWithValue(
              ProductionPlanRepository(api),
            ),
            masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.productionPlanEdit,
              Perm.productionPlanApprove,
              Perm.productionMaterialAnalysisView,
            }),
          ],
          child: const MaterialApp(
            home: ProductionPlanDetailPage(id: 'plan-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('return-to-material-analysis')),
        findsOneWidget,
      );
      expect(find.text('回到物料分析'), findsOneWidget);
      expect(find.text('编辑'), findsNothing);
      expect(find.text('删除'), findsNothing);
      expect(find.text('审核'), findsOneWidget);
      expect(find.textContaining('明细 ('), findsNothing);
      expect(
        find.byKey(const Key('production-plan-draft-product-summary')),
        findsOneWidget,
      );
      expect(find.text('计划产品摘要'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('draft edit permission does not reveal delete action', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _plainDraftPlanDetailApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          productionWriteAllDocumentScope(),
          productionPlanRepositoryProvider.overrideWithValue(
            ProductionPlanRepository(api),
          ),
          masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.productionPlanView,
            Perm.productionPlanEdit,
          }),
        ],
        child: const MaterialApp(home: ProductionPlanDetailPage(id: 'plan-1')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('删除'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('draft delete permission does not reveal edit action', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _plainDraftPlanDetailApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          productionWriteAllDocumentScope(),
          productionPlanRepositoryProvider.overrideWithValue(
            ProductionPlanRepository(api),
          ),
          masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.productionPlanView,
            Perm.productionPlanDelete,
          }),
        ],
        child: const MaterialApp(home: ProductionPlanDetailPage(id: 'plan-1')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('删除'), findsOneWidget);
    expect(find.text('编辑'), findsNothing);
    expect(find.byKey(const Key('production-print-plan')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'approved plan exposes direct production-plan print and loads work card',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(375, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _approvedPlanDetailApi();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            productionWriteAllDocumentScope(),
            productionPlanRepositoryProvider.overrideWithValue(
              ProductionPlanRepository(api),
            ),
            masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.productionPlanView,
              Perm.productionPlanReverse,
            }),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!,
            ),
            home: const ProductionPlanDetailPage(id: 'plan-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final printPlan = find.byKey(const Key('production-print-plan'));
      expect(printPlan, findsOneWidget);
      expect(find.text('红冲'), findsOneWidget);
      await tester.ensureVisible(printPlan);
      expect(tester.takeException(), isNull);
      await tester.tap(printPlan);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      expect(find.text('A4 生产计划单 · 流水线执行工卡'), findsOneWidget);
      expect(find.textContaining('SEG-001 · 测试产品'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭生产计划打印预览'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('stopped approved plan keeps print action disabled', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _approvedPlanDetailApi(stopped: true);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          productionWriteAllDocumentScope(),
          productionPlanRepositoryProvider.overrideWithValue(
            ProductionPlanRepository(api),
          ),
          masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.productionPlanView,
          }),
        ],
        child: const MaterialApp(home: ProductionPlanDetailPage(id: 'plan-1')),
      ),
    );
    await tester.pumpAndSettle();

    final printPlan = find.byKey(const Key('production-print-plan'));
    expect(printPlan, findsOneWidget);
    expect(tester.widget<UtenButton>(printPlan).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'approved reverse action uses production plan reverse permission',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _approvedPlanDetailApi();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            productionWriteAllDocumentScope(),
            productionPlanRepositoryProvider.overrideWithValue(
              ProductionPlanRepository(api),
            ),
            masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.productionPlanView,
              Perm.productionPlanReverse,
            }),
          ],
          child: const MaterialApp(
            home: ProductionPlanDetailPage(id: 'plan-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('红冲'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'planning-package cancel permission does not reveal reverse action',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _approvedPlanDetailApi();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            productionWriteAllDocumentScope(),
            productionPlanRepositoryProvider.overrideWithValue(
              ProductionPlanRepository(api),
            ),
            masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.productionPlanView,
              Perm.productionPlanningPackageCancel,
            }),
          ],
          child: const MaterialApp(
            home: ProductionPlanDetailPage(id: 'plan-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final openResult = find.text('查看执行单据');
      await tester.ensureVisible(openResult);
      await tester.tap(openResult);
      await tester.pumpAndSettle();

      expect(find.text('取消计划包'), findsOneWidget);
      expect(find.text('冲销计划包'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('plan detail exposes report only with daily view and create', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Future<void> pumpWith(Set<String> permissions) async {
      final api = _approvedPlanDetailApi(withInProgressSegment: true);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            productionWriteAllDocumentScope(),
            productionPlanRepositoryProvider.overrideWithValue(
              ProductionPlanRepository(api),
            ),
            masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
            currentPermissionsProvider.overrideWithValue(permissions),
          ],
          child: const MaterialApp(
            home: ProductionPlanDetailPage(id: 'plan-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final segment = find.text('SEG-001');
      await tester.ensureVisible(segment);
      await tester.pumpAndSettle();
      await tester.tap(segment);
      await tester.pumpAndSettle();
    }

    await pumpWith(const {
      Perm.productionPlanView,
      Perm.productionDailyReportEdit,
    });
    expect(find.text('分批报工'), findsNothing);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    await pumpWith(const {
      Perm.productionPlanView,
      Perm.productionDailyReportView,
      Perm.productionDailyReportCreate,
    });
    expect(find.text('分批报工'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

ApiClient _directMakeApprovedPlanDetailApi(
  List<RequestOptions> requests, {
  bool withSegment = true,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        requests.add(request);
        final Object data = switch (request.path) {
          '/production/plans/plan-1' => <String, dynamic>{
            'id': 'plan-1',
            'makerId': 'maker-1',
            'billNo': 'SJ-1',
            'billDate': '2026-08-29',
            'status': 1,
            'materialAnalysisId': 'analysis-1',
            'allowedActions': ['VIEW'],
            'items': <Map<String, dynamic>>[],
          },
          '/production/plans/plan-1/mrp/subplans' => <Map<String, dynamic>>[],
          '/production/plans/plan-1/mrp/planning-package-result' =>
            <String, dynamic>{},
          '/production/plans/plan-1/execution-segments' =>
            withSegment
                ? <Map<String, dynamic>>[
                    {
                      'id': 'segment-1',
                      'packageId': 'package-1',
                      'planId': 'plan-1',
                      'sourcePlanItemId': 'plan-item-1',
                      'segmentNo': 1,
                      'segmentCode': 'ZX-001',
                      'productGoodsId': 'goods-1',
                      'productCode': 'P-001',
                      'productName': '直接自制产品',
                      'productUnitId': 'unit-1',
                      'plannedQty': 10,
                      'reportedQty': 0,
                      'remainingQty': 10,
                      'status': 'READY',
                      'autoPromoteWhenReady': true,
                      'materialKindCount': 0,
                      'shortageKindCount': 0,
                      'materialReady': true,
                      'materialDemandCount': 0,
                      'fullyIssuedDemandCount': 0,
                      'materialIssued': true,
                      'lockVersion': 1,
                    },
                  ]
                : <Map<String, dynamic>>[],
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

ApiClient _planDetailApi() {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        final Object data = switch (request.path) {
          '/production/plans/plan-1' => <String, dynamic>{
            'id': 'plan-1',
            'makerId': 'maker-1',
            'billNo': 'SJ-1',
            'billDate': '2026-08-08',
            'status': 0,
            'materialAnalysisId': 'analysis-1',
            'materialAnalysisItemId': 'analysis-line-1',
            'allowedActions': [
              'VIEW',
              'RETURN_TO_MATERIAL_ANALYSIS',
              'APPROVE',
            ],
            'items': <Map<String, dynamic>>[],
          },
          '/production/plans/plan-1/mrp/planning-draft' => <String, dynamic>{},
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

ApiClient _plainDraftPlanDetailApi() {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        final Object data = switch (request.path) {
          '/production/plans/plan-1' => <String, dynamic>{
            'id': 'plan-1',
            'makerId': 'maker-1',
            'billNo': 'SJ-1',
            'billDate': '2026-08-08',
            'status': 0,
            'allowedActions': ['VIEW', 'EDIT', 'DELETE'],
            'items': <Map<String, dynamic>>[],
          },
          '/production/plans/plan-1/mrp/planning-draft' => <String, dynamic>{},
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

ApiClient _approvedPlanDetailApi({
  bool withInProgressSegment = false,
  bool stopped = false,
  bool canceled = false,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        final Object data = switch (request.path) {
          '/production/plans/plan-1' => <String, dynamic>{
            'id': 'plan-1',
            'makerId': 'maker-1',
            'billNo': 'SJ-1',
            'billDate': '2026-08-08',
            'status': 1,
            'stopped': stopped,
            'canceled': canceled,
            'allowedActions': ['VIEW', 'REVERSE'],
            'items': <Map<String, dynamic>>[],
          },
          '/production/plans/plan-1/mrp/planning-package-result' =>
            <String, dynamic>{
              'packageId': 'package-1',
              'status': 'CONFIRMED',
              'replayed': true,
              'subplans': <Map<String, dynamic>>[],
              'executionSegments': <Map<String, dynamic>>[],
              'drawDocuments': <Map<String, dynamic>>[],
            },
          '/production/plans/plan-1/planning-packages/package-1/work-cards' =>
            _detailWorkCardJson(),
          '/production/plans/plan-1/execution-segments' =>
            withInProgressSegment
                ? <Map<String, dynamic>>[
                    {
                      'id': 'segment-1',
                      'packageId': 'package-1',
                      'planId': 'plan-1',
                      'sourcePlanItemId': 'plan-item-1',
                      'segmentNo': 1,
                      'segmentCode': 'SEG-001',
                      'productGoodsId': 'goods-1',
                      'productCode': 'P-001',
                      'productName': '测试产品',
                      'productUnitId': 'unit-1',
                      'plannedQty': 10,
                      'reportedQty': 2,
                      'remainingQty': 8,
                      'status': 'IN_PROGRESS',
                      'autoPromoteWhenReady': true,
                      'workshopDepartmentId': 'workshop-1',
                      'workshopName': '装配车间',
                      'responsibleEmployeeId': 'employee-1',
                      'responsibleEmployeeName': '张三',
                      'planBeginDate': '2026-08-28',
                      'planEndDate': '2026-08-29',
                      'materialKindCount': 1,
                      'shortageKindCount': 0,
                      'materialReady': true,
                      'materialDemandCount': 1,
                      'fullyIssuedDemandCount': 1,
                      'materialIssued': true,
                      'lockVersion': 1,
                    },
                  ]
                : <Map<String, dynamic>>[],
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

Map<String, dynamic> _detailWorkCardJson() => {
  'planId': 'plan-1',
  'planBillNo': 'SJ-1',
  'planBillDate': '2026-08-08',
  'deliveryDate': '2026-08-10',
  'packageId': 'package-1',
  'packageStatus': 'CONFIRMED',
  'executionModelVersion': 1,
  'packageLockVersion': 1,
  'confirmedAt': '2026-08-08T08:30:00Z',
  'approverName': '审核员',
  'warehouseId': 'warehouse-1',
  'warehouseCode': 'WH-01',
  'warehouseName': '主仓',
  'generatedAt': '2026-08-08T08:31:00Z',
  'namePolicy': 'CURRENT_MASTER_DATA',
  'cards': [
    {
      'segmentId': 'segment-1',
      'segmentCode': 'SEG-001',
      'sourcePlanItemId': 'plan-item-1',
      'sourceLineNo': 1,
      'productNo': 'V6-0001',
      'productGoodsId': 'goods-1',
      'productCode': 'P-001',
      'productName': '测试产品',
      'productSpec': '三插压板',
      'productUnitName': '件',
      'plannedQty': 10,
      'status': 'READY',
      'materialRequirementMode': 'ZERO_MATERIAL',
      'zeroMaterialReason': 'DIRECT_MAKE',
      'workshopName': '装配一车间',
      'responsibleEmployeeName': '负责人',
      'planBeginDate': '2026-08-08',
      'planEndDate': '2026-08-10',
      'materials': <Map<String, dynamic>>[],
    },
  ],
};
