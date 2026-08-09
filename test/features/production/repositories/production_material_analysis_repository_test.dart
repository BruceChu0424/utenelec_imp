import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';

void main() {
  test('lists object-scoped analysis history with exact filters', () async {
    RequestOptions? captured;
    final repository = ProductionPlanRepository(
      _api((request) {
        captured = request;
        return {
          'items': [
            {
              'analysisId': 'analysis-1',
              'status': 'ACTIVE',
              'version': 2,
              'sourceRefs': ['RW-001'],
            },
          ],
          'page': 2,
          'size': 15,
          'total': 18,
          'totalPages': 2,
        };
      }),
    );

    final page = await repository.materialAnalysisList(
      page: 2,
      size: 15,
      keyword: 'RW-001',
      status: 'ACTIVE',
      sourceType: 'REWORK',
    );

    expect(captured?.method, 'GET');
    expect(captured?.path, '/production/material-analyses');
    expect(captured?.queryParameters, {
      'page': 2,
      'size': 15,
      'keyword': 'RW-001',
      'status': 'ACTIVE',
      'sourceType': 'REWORK',
    });
    expect(page.items.single.sourceRefs, ['RW-001']);
    expect(page.total, 18);
  });

  test(
    'uses the frozen CAS bodies for the complete analysis workflow',
    () async {
      final requests = <RequestOptions>[];
      final repository = ProductionPlanRepository(
        _api((request) {
          requests.add(request);
          if (request.path.endsWith('/plan-preview')) return _planPreviewJson;
          if (request.path.endsWith('/generate-plan')) {
            return {
              'analysis': _analysisJson,
              'replayed': false,
              'plans': <Map<String, dynamic>>[],
            };
          }
          return _analysisJson;
        }),
      );

      final analysis = await repository.previewMaterialAnalysis(
        analysisId: 'analysis-1',
        expectedVersion: 6,
        analysisFingerprint: 'a' * 64,
        warehouseId: 'warehouse-1',
        idempotencyKey: 'preview-command-1',
        sources: const [
          MaterialAnalysisSourceInput(
            salesOrderItemId: 'sales-line-1',
            requestedQty: 8,
          ),
          MaterialAnalysisSourceInput(
            sourceType: 'SAMPLE',
            sourceRef: 'SAMPLE-20260808-001',
            goodsId: 'goods-2',
            requestedQty: 2,
            sourceReason: '展会样品',
          ),
        ],
      );
      await repository.updateMaterialAnalysisRoutes(
        analysis: analysis,
        idempotencyKey: 'route-command-1',
        decisions: const [
          MaterialRouteDecision(
            actionGroupKey: 'action-group-1',
            route: MaterialSupplyRoute.make,
            reason: '交期要求改为自制',
          ),
        ],
      );
      await repository.notifyMaterialAnalysis(
        analysis: analysis,
        idempotencyKey: 'notify-command-1',
        target: MaterialSupplyRoute.make,
        actionGroupKeys: const ['action-group-1'],
      );
      final planPreview = await repository.previewMaterialAnalysisPlan(
        analysis: analysis,
        warehouseId: 'warehouse-1',
        items: const [
          MaterialAnalysisPlanItemInput(
            analysisLineId: 'product-line-1',
            qty: 5,
            billDate: '2026-08-09',
            deliveryDate: '2026-08-18',
            departmentId: 'workshop-1',
            workshopName: '装配一车间',
            workerId: 'worker-1',
            teamDepartmentId: 'team-1',
          ),
        ],
        bomOverrides: const [
          MaterialBomOverride(
            analysisLineId: 'product-line-1',
            reason: '试制特批，后续补录 BOM',
          ),
        ],
      );
      await repository.generateMaterialAnalysisPlan(
        preview: planPreview,
        warehouseId: 'warehouse-1',
        idempotencyKey: 'generate-command-1',
        billDate: '2026-08-08',
        deliveryDate: '2026-08-20',
        departmentId: 'fallback-workshop',
        workshopName: '默认车间',
        workerId: 'fallback-worker',
        items: const [
          MaterialAnalysisPlanItemInput(
            analysisLineId: 'product-line-1',
            qty: 5,
            billDate: '2026-08-09',
            deliveryDate: '2026-08-18',
            departmentId: 'workshop-1',
            workshopName: '装配一车间',
            workerId: 'worker-1',
            teamDepartmentId: 'team-1',
          ),
        ],
        bomOverrides: const [
          MaterialBomOverride(
            analysisLineId: 'product-line-1',
            reason: '试制特批，后续补录 BOM',
          ),
        ],
      );
      await repository.updateMaterialAllocationPriorities(
        analysis: analysis,
        idempotencyKey: 'priority-command-1',
        items: const [
          MaterialAllocationPriorityInput(
            analysisLineId: 'product-line-2',
            priority: 1,
          ),
          MaterialAllocationPriorityInput(
            analysisLineId: 'product-line-1',
            priority: 2,
          ),
        ],
      );

      expect(requests[0].method, 'POST');
      expect(requests[0].path, '/production/material-analyses/preview');
      expect(requests[0].data, {
        'analysisId': 'analysis-1',
        'version': 6,
        'fingerprint': 'a' * 64,
        'warehouseId': 'warehouse-1',
        'idempotencyKey': 'preview-command-1',
        'sources': [
          {'salesOrderItemId': 'sales-line-1', 'requestedQty': 8.0},
          {
            'sourceType': 'SAMPLE',
            'sourceRef': 'SAMPLE-20260808-001',
            'goodsId': 'goods-2',
            'requestedQty': 2.0,
            'sourceReason': '展会样品',
          },
        ],
      });
      expect(requests[1].method, 'PUT');
      expect(requests[1].data, {
        'version': 7,
        'fingerprint': 'b' * 64,
        'idempotencyKey': 'route-command-1',
        'decisions': [
          {
            'actionGroupKey': 'action-group-1',
            'route': 'MAKE',
            'reason': '交期要求改为自制',
          },
        ],
      });
      expect(requests[2].data, {
        'version': 7,
        'fingerprint': 'b' * 64,
        'idempotencyKey': 'notify-command-1',
        'target': 'MAKE',
        'actionGroupKeys': ['action-group-1'],
      });
      expect(requests[3].data, {
        'version': 7,
        'fingerprint': 'b' * 64,
        'warehouseId': 'warehouse-1',
        'items': [
          {'analysisLineId': 'product-line-1', 'qty': 5.0},
        ],
        'bomOverrides': [
          {'analysisLineId': 'product-line-1', 'reason': '试制特批，后续补录 BOM'},
        ],
      });
      expect(requests[4].data, {
        'version': 7,
        'fingerprint': 'b' * 64,
        'previewFingerprint': 'c' * 64,
        'warehouseId': 'warehouse-1',
        'idempotencyKey': 'generate-command-1',
        'billDate': '2026-08-08',
        'deliveryDate': '2026-08-20',
        'departmentId': 'fallback-workshop',
        'workshopName': '默认车间',
        'workerId': 'fallback-worker',
        'approveNow': false,
        'items': [
          {
            'analysisLineId': 'product-line-1',
            'qty': 5.0,
            'billDate': '2026-08-09',
            'deliveryDate': '2026-08-18',
            'departmentId': 'workshop-1',
            'workshopName': '装配一车间',
            'workerId': 'worker-1',
            'teamDepartmentId': 'team-1',
          },
        ],
        'bomOverrides': [
          {'analysisLineId': 'product-line-1', 'reason': '试制特批，后续补录 BOM'},
        ],
      });
      expect(requests[5].method, 'PUT');
      expect(
        requests[5].path,
        '/production/material-analyses/analysis-1/allocation-priorities',
      );
      expect(requests[5].data, {
        'version': 7,
        'fingerprint': 'b' * 64,
        'idempotencyKey': 'priority-command-1',
        'items': [
          {'analysisLineId': 'product-line-2', 'priority': 1},
          {'analysisLineId': 'product-line-1', 'priority': 2},
        ],
      });
    },
  );

  test('pending schedule tolerantly parses material-analysis projection', () {
    final row = SchedulePendingRow.fromJson({
      'orderItemId': 'sales-line-1',
      'orderId': 'sales-order-1',
      'materialAnalysisId': 'analysis-1',
      'materialAnalysisLineId': 'product-line-1',
      'materialAnalysisStatus': 'ANALYZED',
      'materialAnalysisVersion': 8,
      'materialAnalyzedAt': '2026-08-08T10:00:00Z',
      'analyzedQty': 10,
      'submittedPlanQty': 4,
      'approvedPlannedQty': 2,
      'readyNowQty': 3,
      'readyByDateQty': 7,
      'readinessRatio': 40,
    });

    expect(row.materialAnalysisLineId, 'product-line-1');
    expect(row.materialAnalysisVersion, 8);
    expect(row.analyzedQty, 10);
    expect(row.submittedPlanQty, 4);
    expect(row.approvedPlannedQty, 2);
    expect(row.readyNowQty, 3);
    expect(row.readyByDateQty, 7);
    expect(row.readinessRatio, 0.4);
  });
}

final _analysisJson = <String, dynamic>{
  'analysisId': 'analysis-1',
  'status': 'ANALYZED',
  'version': 7,
  'fingerprint': 'b' * 64,
  'warehouseId': 'warehouse-1',
  'products': [
    {
      'analysisLineId': 'product-line-1',
      'requestedQty': 8,
      'readyNowQty': 5,
      'readinessRatio': 0.625,
      'allocationPriority': 1,
    },
    {
      'analysisLineId': 'product-line-2',
      'requestedQty': 4,
      'readyNowQty': 2,
      'readinessRatio': 0.5,
      'allocationPriority': 2,
    },
  ],
  'flatMaterials': <Map<String, dynamic>>[],
  'warehouses': <Map<String, dynamic>>[],
  'allowedActions': ['PLAN_PREVIEW', 'GENERATE_PLAN'],
};

final _planPreviewJson = <String, dynamic>{
  'analysisId': 'analysis-1',
  'version': 7,
  'fingerprint': 'b' * 64,
  'previewFingerprint': 'c' * 64,
  'warehouseId': 'warehouse-1',
  'allReady': true,
  'items': [
    {
      'analysisLineId': 'product-line-1',
      'requestedQty': 8,
      'readyNowQty': 5,
      'selectedQty': 5,
      'canGenerate': true,
    },
  ],
  'plans': <Map<String, dynamic>>[],
  'allowedActions': ['GENERATE_PLAN'],
};

ApiClient _api(Object? Function(RequestOptions request) responder) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) => handler.resolve(
        Response<dynamic>(
          requestOptions: request,
          statusCode: 200,
          data: responder(request),
        ),
      ),
    ),
  );
  return ApiClient(dio);
}
