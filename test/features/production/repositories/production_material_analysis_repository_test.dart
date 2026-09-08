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
          if (request.path.endsWith('/issue-plans')) {
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
      await repository.issueWorkshopPlans(
        analysis: analysis,
        warehouseId: 'warehouse-1',
        idempotencyKey: 'issue-command-1',
        billDate: '2026-08-08',
        deliveryDate: '2026-08-20',
        approveNow: true,
        lines: const [
          MaterialAnalysisIssueLine(
            analysisLineId: 'product-line-1',
            qty: 5,
            departmentId: 'workshop-1',
            workshopName: '装配一车间',
            workerId: 'worker-1',
          ),
          MaterialAnalysisIssueLine(
            materialLineId: 'material-line-1',
            qty: 8,
            departmentId: 'workshop-2',
            workshopName: '装配二车间',
            workerId: 'worker-2',
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
        'warehouseIds': ['warehouse-1'],
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
        'idempotencyKey': 'issue-command-1',
        'billDate': '2026-08-08',
        'deliveryDate': '2026-08-20',
        'approveNow': true,
        'lines': [
          {
            'analysisLineId': 'product-line-1',
            'qty': 5.0,
            'departmentId': 'workshop-1',
            'workshopName': '装配一车间',
            'workerId': 'worker-1',
          },
          {
            'materialLineId': 'material-line-1',
            'qty': 8.0,
            'departmentId': 'workshop-2',
            'workshopName': '装配二车间',
            'workerId': 'worker-2',
          },
        ],
      });
      expect(requests[4].method, 'PUT');
      expect(
        requests[4].path,
        '/production/material-analyses/analysis-1/allocation-priorities',
      );
      expect(requests[4].data, {
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

  test(
    'uses exact cross-plan candidate and dual-CAS mutation contracts',
    () async {
      final requests = <RequestOptions>[];
      final repository = ProductionPlanRepository(
        _api((request) {
          requests.add(request);
          if (request.method == 'GET' &&
              request.path.endsWith('/cross-reallocation-candidates')) {
            return {
              'items': [
                {
                  'targetAnalysisId': 'target-analysis',
                  'targetVersion': 3,
                  'targetFingerprint': 'c' * 64,
                  'targetMaterialLineId': 'target-material',
                  'analysisLabel': '订单 XS-002',
                  'shortageQty': 6,
                  'sourceLendableQty': 4,
                },
              ],
              'page': 1,
              'size': 15,
              'total': 1,
              'totalPages': 1,
            };
          }
          return _analysisJson;
        }),
      );

      final page = await repository.materialCrossReallocationCandidates(
        sourceAnalysisId: 'analysis-1',
        sourceMaterialLineId: 'source-material',
        size: 15,
        keyword: 'XS-002',
      );
      final target = page.items.single;
      expect(target.sourceLendableQty, 4);
      final source = ProductionMaterialAnalysisView.fromJson(_analysisJson);
      await repository.createMaterialCrossReallocation(
        sourceAnalysis: source,
        target: target,
        sourceMaterialLineId: 'source-material',
        qty: 4,
        reason: '客户加急',
        idempotencyKey: 'cross-reallocation-create-1',
      );
      await repository.revokeMaterialCrossReallocation(
        sourceAnalysisId: 'analysis-1',
        sourceVersion: 7,
        sourceFingerprint: 'b' * 64,
        targetAnalysisId: 'target-analysis',
        targetVersion: 3,
        targetFingerprint: 'c' * 64,
        crossReallocationId: 'allocation-1',
        reason: '交期调整',
        idempotencyKey: 'cross-reallocation-revoke-1',
      );

      expect(requests[0].method, 'GET');
      expect(
        requests[0].path,
        '/production/material-analyses/analysis-1/materials/source-material/'
        'cross-reallocation-candidates',
      );
      expect(requests[0].queryParameters, {
        'page': 1,
        'size': 15,
        'keyword': 'XS-002',
      });
      expect(requests[1].method, 'POST');
      expect(
        requests[1].path,
        '/production/material-analyses/analysis-1/cross-reallocations',
      );
      expect(requests[1].data, {
        'sourceVersion': 7,
        'sourceFingerprint': 'b' * 64,
        'sourceMaterialLineId': 'source-material',
        'targetAnalysisId': 'target-analysis',
        'targetVersion': 3,
        'targetFingerprint': 'c' * 64,
        'targetMaterialLineId': 'target-material',
        'qty': 4.0,
        'reason': '客户加急',
        'idempotencyKey': 'cross-reallocation-create-1',
      });
      expect(requests[2].method, 'POST');
      expect(
        requests[2].path,
        '/production/material-analyses/analysis-1/cross-reallocations/'
        'allocation-1/revoke',
      );
      expect(requests[2].data, {
        'sourceVersion': 7,
        'sourceFingerprint': 'b' * 64,
        'targetVersion': 3,
        'targetFingerprint': 'c' * 64,
        'reason': '交期调整',
        'idempotencyKey': 'cross-reallocation-revoke-1',
      });
    },
  );

  test(
    'notify sends demand and safety replenishment as explicit slices',
    () async {
      RequestOptions? captured;
      final repository = ProductionPlanRepository(
        _api((request) {
          captured = request;
          return _analysisJson;
        }),
      );
      final analysis = ProductionMaterialAnalysisView.fromJson(_analysisJson);

      await repository.notifyMaterialAnalysis(
        analysis: analysis,
        idempotencyKey: 'notify-safety-split-1',
        target: MaterialSupplyRoute.buy,
        actionGroupKeys: const ['action-group-1'],
        quantities: const [
          MaterialSupplyQuantityInput(
            actionGroupKey: 'action-group-1',
            qty: 0,
            safetyReplenishmentQty: 6,
          ),
        ],
      );

      expect(captured?.method, 'POST');
      expect(captured?.data, {
        'version': 7,
        'fingerprint': 'b' * 64,
        'idempotencyKey': 'notify-safety-split-1',
        'target': 'BUY',
        'actionGroupKeys': ['action-group-1'],
        'quantities': [
          {
            'actionGroupKey': 'action-group-1',
            'qty': 0.0,
            'safetyReplenishmentQty': 6.0,
            'publicExtraQty': 0.0,
          },
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
