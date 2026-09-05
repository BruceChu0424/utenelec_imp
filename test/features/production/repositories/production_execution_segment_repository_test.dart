import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';

void main() {
  test(
    'lists persisted execution segments with progress and version',
    () async {
      final repository = ProductionPlanRepository(
        _api((request) {
          expect(request.method, 'GET');
          expect(request.path, '/production/plans/plan-1/execution-segments');
          return [_segmentJson(status: 'IN_PROGRESS', lockVersion: 4)];
        }),
      );

      final rows = await repository.executionSegments('plan-1');

      expect(rows.single.segmentCode, 'SEG-001');
      expect(rows.single.reportedQty, 3);
      expect(rows.single.remainingQty, 7);
      expect(rows.single.ordinaryRemainingQty, 5);
      expect(rows.single.fqcPendingQty, 2);
      expect(rows.single.finishedInboundPendingQty, 1);
      expect(rows.single.inboundQty, 4);
      expect(rows.single.finishedInboundRejectedQty, 3);
      expect(rows.single.fqcRecoveryAvailableQty, 2);
      expect(rows.single.fqcReworkAvailableQty, 2);
      expect(rows.single.fqcReplacementReadyQty, 1);
      expect(rows.single.status, 'IN_PROGRESS');
      expect(rows.single.lockVersion, 4);
    },
  );

  test('assignment uses PATCH and sends expectedVersion idempotency', () async {
    late RequestOptions captured;
    final repository = ProductionPlanRepository(
      _api((request) {
        captured = request;
        return _segmentJson(status: 'READY', lockVersion: 2);
      }),
    );

    final result = await repository.assignExecutionSegment(
      'plan-1',
      'segment-1',
      expectedVersion: 1,
      idempotencyKey: 'segment-assign-001',
      workshopDepartmentId: 'workshop-1',
      teamDepartmentId: 'team-1',
      responsibleEmployeeId: 'employee-1',
      planBeginDate: '2026-08-01',
      planEndDate: '2026-08-02',
    );

    expect(captured.method, 'PATCH');
    expect(
      captured.path,
      '/production/plans/plan-1/execution-segments/segment-1/assignment',
    );
    expect(captured.data, {
      'expectedVersion': 1,
      'idempotencyKey': 'segment-assign-001',
      'workshopDepartmentId': 'workshop-1',
      'teamDepartmentId': 'team-1',
      'responsibleEmployeeId': 'employee-1',
      'planBeginDate': '2026-08-01',
      'planEndDate': '2026-08-02',
    });
    expect(result.lockVersion, 2);
  });

  test('release defer is the only client-exposed segment transition', () async {
    late RequestOptions captured;
    final repository = ProductionPlanRepository(
      _api((request) {
        captured = request;
        return _segmentJson(status: 'WAITING', lockVersion: 3);
      }),
    );

    final result = await repository.releaseDeferredExecutionSegment(
      'plan-1',
      'segment-1',
      expectedVersion: 2,
      idempotencyKey: 'segment-release-defer-001',
    );

    expect(captured.method, 'POST');
    expect(
      captured.path,
      '/production/plans/plan-1/execution-segments/segment-1/release-defer',
    );
    expect(captured.data, {
      'expectedVersion': 2,
      'idempotencyKey': 'segment-release-defer-001',
    });
    expect(result.status, 'WAITING');
  });
}

Map<String, dynamic> _segmentJson({
  required String status,
  required int lockVersion,
}) {
  return {
    'id': 'segment-1',
    'packageId': 'package-1',
    'planId': 'plan-1',
    'sourcePlanItemId': 'plan-item-1',
    'segmentNo': 1,
    'segmentCode': 'SEG-001',
    'productGoodsId': 'goods-1',
    'productCode': 'P-001',
    'productName': '成品灯',
    'productColorId': null,
    'productUnitId': 'unit-1',
    'plannedQty': 10,
    'reportedQty': 3,
    'remainingQty': 7,
    'ordinaryRemainingQty': 5,
    'fqcPendingQty': 2,
    'fqcPassedQty': 5,
    'fqcFailedQty': 2,
    'finishedInboundPendingQty': 1,
    'inboundQty': 4,
    'finishedInboundRejectedQty': 3,
    'fqcRecoveryAvailableQty': 2,
    'fqcReworkAvailableQty': 2,
    'fqcReplacementAvailableQty': 0,
    'fqcReplacementReadyQty': 1,
    'status': status,
    'workshopDepartmentId': 'workshop-1',
    'workshopName': '装配一车间',
    'teamDepartmentId': 'team-1',
    'teamName': '甲班',
    'responsibleEmployeeId': 'employee-1',
    'responsibleEmployeeName': '张三',
    'planBeginDate': '2026-08-01',
    'planEndDate': '2026-08-02',
    'materialKindCount': 2,
    'shortageKindCount': 0,
    'materialReady': true,
    'lockVersion': lockVersion,
  };
}

ApiClient _api(Object? Function(RequestOptions request) responder) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: responder(request),
          ),
        );
      },
    ),
  );
  return ApiClient(dio);
}
