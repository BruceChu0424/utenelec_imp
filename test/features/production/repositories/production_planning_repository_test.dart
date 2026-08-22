import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/production/models/production_execution_planning.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';

void main() {
  test(
    'loads and saves a planning draft using the dedicated contract',
    () async {
      final requests = <RequestOptions>[];
      final repository = ProductionPlanRepository(
        _api((request) {
          requests.add(request);
          return {
            'draftId': 'draft-1',
            'planId': 'plan-1',
            'warehouseId': 'warehouse-1',
            'status': 'ACTIVE',
            'previewFingerprint': 'a' * 64,
            'segmentCount': 1,
            'generatePurchaseRequest': true,
            'plannedAt': '2026-08-02T08:30:00Z',
            'plannedBy': 'user-1',
            'request': {
              'routes': [
                {'goodsId': 'material-1', 'supplyRoute': 'SUBCONTRACT'},
              ],
              'segments': [
                {
                  'clientSegmentKey': 'line-1-ready',
                  'sourcePlanItemId': 'plan-item-1',
                  'requestedStatus': 'READY',
                  'plannedQty': 2.5,
                  'workshopDepartmentId': 'workshop-1',
                  'bomFingerprint': 'b' * 64,
                },
              ],
            },
          };
        }),
      );
      const request = ProductionPlanningConfirmRequest(
        warehouseId: 'warehouse-1',
        idempotencyKey: 'planning-1',
        previewFingerprint:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        generatePurchaseRequest: true,
      );

      final loaded = await repository.planningDraft('plan-1');
      final saved = await repository.savePlanningDraft('plan-1', request);

      expect(loaded.draftId, 'draft-1');
      expect(loaded.status, 'ACTIVE');
      expect(loaded.routes.single.supplyRoute, 'SUBCONTRACT');
      expect(loaded.segments.single.clientSegmentKey, 'line-1-ready');
      expect(loaded.segments.single.workshopDepartmentId, 'workshop-1');
      expect(saved.segmentCount, 1);
      expect(saved.segments.single.plannedQty, 2.5);
      expect(requests[0].method, 'GET');
      expect(requests[0].path, '/production/plans/plan-1/mrp/planning-draft');
      expect(requests[1].method, 'PUT');
      expect(requests[1].path, '/production/plans/plan-1/mrp/planning-draft');
      expect(requests[1].data, request.toJson());
    },
  );

  test('loads the latest confirmed planning package result', () async {
    late RequestOptions captured;
    final repository = ProductionPlanRepository(
      _api((request) {
        captured = request;
        return {
          'packageId': 'package-1',
          'status': 'CONFIRMED',
          'replayed': true,
          'subplans': [
            {'planId': 'child-plan-1', 'billNo': 'PP-CHILD-1', 'lineCount': 1},
          ],
          'purchaseRequest': {
            'requestId': 'purchase-1',
            'requestBillNo': 'PR-1',
            'lineCount': 1,
          },
          'drawDocuments': [
            {'requestId': 'draw-1', 'requestBillNo': 'DRAW-1', 'lineCount': 1},
          ],
          'executionSegments': const <Map<String, dynamic>>[],
        };
      }),
    );

    final result = await repository.latestPlanningPackageResult('plan-1');

    expect(
      captured.path,
      '/production/plans/plan-1/mrp/planning-package-result',
    );
    expect(captured.method, 'GET');
    expect(result.packageId, 'package-1');
    expect(result.subplans.single.planId, 'child-plan-1');
    expect(result.purchaseRequest?.requestId, 'purchase-1');
    expect(result.drawDocuments.single.requestId, 'draw-1');
  });

  test(
    'cancel and reverse share one typed lifecycle request contract',
    () async {
      final requests = <RequestOptions>[];
      final repository = ProductionPlanRepository(
        _api((request) {
          requests.add(request);
          return <String, dynamic>{};
        }),
      );

      await repository.changePlanningPackageLifecycle(
        'plan-1',
        'package-1',
        ProductionPlanningPackageLifecycleAction.cancel,
        idempotencyKey: 'package-cancel-001',
        reason: '订单已取消',
      );
      await repository.changePlanningPackageLifecycle(
        'plan-1',
        'package-1',
        ProductionPlanningPackageLifecycleAction.reverse,
        idempotencyKey: 'package-reverse-001',
        reason: '计划下达错误',
      );

      expect(requests.map((request) => request.method), everyElement('POST'));
      expect(requests.map((request) => request.path), [
        '/production/plans/plan-1/mrp/planning-packages/package-1/cancel',
        '/production/plans/plan-1/mrp/planning-packages/package-1/reverse',
      ]);
      expect(requests[0].data, {
        'idempotencyKey': 'package-cancel-001',
        'reason': '订单已取消',
      });
      expect(requests[1].data, {
        'idempotencyKey': 'package-reverse-001',
        'reason': '计划下达错误',
      });
    },
  );

  test('loads confirmed production work cards without writing state', () async {
    late RequestOptions captured;
    final repository = ProductionPlanRepository(
      _api((request) {
        captured = request;
        return {
          'planId': 'plan-1',
          'planBillNo': 'PP-001',
          'packageId': 'package-1',
          'packageStatus': 'CONFIRMED',
          'executionModelVersion': 1,
          'packageLockVersion': 3,
          'warehouseId': 'warehouse-1',
          'warehouseName': '原料仓',
          'generatedAt': '2026-08-02T09:00:00Z',
          'namePolicy': 'CURRENT_MASTER_DATA',
          'cards': [
            {
              'segmentId': 'segment-1',
              'segmentCode': 'SEG-001',
              'sourcePlanItemId': 'item-1',
              'productGoodsId': 'product-1',
              'productCode': 'P-001',
              'productName': '测试产品',
              'productSpec': 'M8 x 30',
              'plannedQty': 10,
              'status': 'READY',
              'materials': [
                {
                  'demandId': 'demand-1',
                  'goodsId': 'material-1',
                  'goodsCode': 'M-001',
                  'goodsName': '测试物料',
                  'spec': 'ABS',
                  'perProductQty': 2,
                  'requiredQty': 20,
                  'stockAllocatedQty': 20,
                  'shortageQty': 0,
                  'supplyRoute': 'BUY',
                  'demandStatus': 'ALLOCATED',
                },
              ],
            },
          ],
        };
      }),
    );

    final view = await repository.productionWorkCards('plan-1', 'package-1');

    expect(captured.method, 'GET');
    expect(
      captured.path,
      '/production/plans/plan-1/planning-packages/package-1/work-cards',
    );
    expect(view.isPrintable, isTrue);
    expect(view.cards.single.productSpec, 'M8 x 30');
    expect(view.cards.single.materials.single.goodsCode, 'M-001');
  });

  test('maps an empty optional result to NOT_FOUND', () async {
    final repository = ProductionPlanRepository(_api((_) => null));

    await expectLater(
      repository.planningDraft('plan-1'),
      throwsA(
        isA<ApiException>().having((error) => error.code, 'code', 'NOT_FOUND'),
      ),
    );
    await expectLater(
      repository.latestPlanningPackageResult('plan-1'),
      throwsA(
        isA<ApiException>().having((error) => error.code, 'code', 'NOT_FOUND'),
      ),
    );
    await expectLater(
      repository.productionWorkCards('plan-1', 'package-1'),
      throwsA(
        isA<ApiException>().having((error) => error.code, 'code', 'NOT_FOUND'),
      ),
    );
  });

  test(
    'loads learned workshop preferences in proxy-safe 100-id chunks',
    () async {
      final requests = <RequestOptions>[];
      final repository = ProductionPlanRepository(
        _api((request) {
          requests.add(request);
          final ids = (request.queryParameters['ids'] as String).split(',');
          return [
            {
              'goodsId': ids.first,
              'departmentId': 'workshop-${requests.length}',
              'departmentName': '车间 ${requests.length}',
            },
          ];
        }),
      );
      final goodsIds = {
        for (var index = 0; index < 201; index++)
          'goods-${index.toString().padLeft(3, '0')}',
      };

      final result = await repository.defaultWorkshops(goodsIds);

      expect(requests, hasLength(3));
      expect(
        requests.map((request) => request.path),
        everyElement('/production/material-analyses/default-workshops'),
      );
      expect(
        (requests.first.queryParameters['ids'] as String).split(','),
        hasLength(100),
      );
      expect(
        (requests.last.queryParameters['ids'] as String).split(','),
        hasLength(1),
      );
      expect(result['goods-000']?.departmentId, 'workshop-1');
      expect(result['goods-200']?.departmentId, 'workshop-3');
    },
  );
}

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
