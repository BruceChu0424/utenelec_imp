import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/production_execution_planning.dart';

void main() {
  test('decodes V155 planning preview and nested execution materials', () {
    final preview = ProductionPlanningPreview.fromJson({
      'planId': 'plan-1',
      'warehouseId': 'warehouse-1',
      'fingerprint': 'a' * 64,
      'materials': [
        {
          'goodsId': 'material-1',
          'goodsCode': 'M-001',
          'gross': 8,
          'availableNow': 6.5,
          'timelyShortage': 1.5,
          'materialStatus': 'PARTIAL_SHORTAGE',
          'allocationBacked': true,
          'planningWriteReady': true,
        },
      ],
      'targetWarehouseMaterials': [
        {
          'goodsId': 'material-1',
          'colorId': null,
          'requiredQty': 8,
          'allocatableQty': 6,
          'candidateAllocatedQty': 6,
          'candidateShortageQty': 2,
        },
      ],
      'balancedKitCoverage': false,
      'executionSegmentationReady': true,
      'executionSegments': [
        {
          'clientSegmentKey': 'line-1-ready',
          'sourcePlanItemId': 'plan-item-1',
          'sourceLineNo': 1,
          'productGoodsId': 'product-1',
          'productCode': 'P-001',
          'productName': 'Product',
          'productColorId': null,
          'productUnitId': 'unit-product',
          'plannedQty': 6,
          'suggestedStatus': 'READY',
          'workshopDepartmentId': 'workshop-1',
          'teamDepartmentId': null,
          'responsibleEmployeeId': null,
          'planBeginDate': '2026-08-01',
          'planEndDate': '2026-08-02',
          'bomFingerprint': 'b' * 64,
          'materials': [
            {
              'goodsId': 'material-1',
              'colorId': null,
              'unitId': 'unit-material',
              'perProductQty': 1.25,
              'requiredQty': 7.5,
              'availableBeforeQty': 8,
              'candidateAllocatedQty': 7.5,
              'shortageQty': 0,
              'supplyRoute': 'BUY',
            },
          ],
        },
      ],
    });

    expect(preview.planId, 'plan-1');
    expect(preview.executionSegmentationReady, isTrue);
    expect(preview.balancedKitCoverage, isFalse);
    expect(preview.materials.single.availableNow, 6.5);
    expect(preview.targetWarehouseMaterials.single.candidateShortageQty, 2);
    expect(preview.executionSegments.single.suggestedStatus, 'READY');
    expect(
      preview.executionSegments.single.materials.single.perProductQty,
      1.25,
    );
  });

  test('encodes exact V155 planning confirmation request', () {
    const request = ProductionPlanningConfirmRequest(
      warehouseId: 'warehouse-1',
      idempotencyKey: 'planning-plan-1-0001',
      previewFingerprint:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      generatePurchaseRequest: true,
      routes: [
        ProductionMaterialRoute(goodsId: 'material-1', supplyRoute: 'BUY'),
      ],
      segments: [
        ProductionExecutionSegmentConfirm(
          clientSegmentKey: 'line-1-waiting',
          sourcePlanItemId: 'plan-item-1',
          requestedStatus: 'WAITING',
          plannedQty: 4,
          workshopDepartmentId: 'workshop-1',
          teamDepartmentId: 'team-1',
          responsibleEmployeeId: 'employee-1',
          planBeginDate: '2026-08-03',
          planEndDate: '2026-08-04',
          bomFingerprint:
              'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        ),
      ],
    );

    final json = request.toJson();
    expect(json, {
      'warehouseId': 'warehouse-1',
      'idempotencyKey': 'planning-plan-1-0001',
      'previewFingerprint': 'a' * 64,
      'generatePurchaseRequest': true,
      'routes': [
        {'goodsId': 'material-1', 'supplyRoute': 'BUY'},
      ],
      'segments': [
        {
          'clientSegmentKey': 'line-1-waiting',
          'sourcePlanItemId': 'plan-item-1',
          'requestedStatus': 'WAITING',
          'plannedQty': 4.0,
          'workshopDepartmentId': 'workshop-1',
          'teamDepartmentId': 'team-1',
          'responsibleEmployeeId': 'employee-1',
          'planBeginDate': '2026-08-03',
          'planEndDate': '2026-08-04',
          'bomFingerprint': 'b' * 64,
        },
      ],
      'items': <Map<String, dynamic>>[],
    });
  });

  test('decodes generated package, segment, purchase and DRAW results', () {
    final result = ProductionPlanningConfirmResult.fromJson({
      'packageId': 'package-1',
      'status': 'CONFIRMED',
      'replayed': false,
      'subplans': const <Map<String, dynamic>>[],
      'purchaseRequest': {
        'requestId': 'purchase-request-1',
        'requestBillNo': 'PR-001',
        'lineCount': 1,
        'skippedSelfMade': const <String>[],
      },
      'subcontractApplication': {
        'requestId': 'subcontract-application-1',
        'requestBillNo': 'SA-001',
        'lineCount': 2,
        'skippedSelfMade': const <String>[],
      },
      'drawDocument': {
        'requestId': 'draw-1',
        'requestBillNo': 'DRAW-001',
        'lineCount': 1,
        'skippedSelfMade': const <String>[],
      },
      'executionSegments': [
        {
          'segmentId': 'segment-1',
          'segmentCode': 'SEG-001',
          'clientSegmentKey': 'line-1-ready',
          'sourcePlanItemId': 'plan-item-1',
          'productGoodsId': 'product-1',
          'productColorId': null,
          'plannedQty': 6,
          'status': 'READY',
          'workshopDepartmentId': 'workshop-1',
          'teamDepartmentId': null,
          'responsibleEmployeeId': null,
          'planBeginDate': '2026-08-01',
          'planEndDate': '2026-08-02',
          'materials': [
            {
              'demandId': 'demand-1',
              'goodsId': 'material-1',
              'colorId': null,
              'unitId': 'unit-1',
              'perProductQty': 1.25,
              'requiredQty': 7.5,
              'stockAllocatedQty': 7.5,
              'shortageQty': 0,
              'supplyRoute': 'BUY',
            },
          ],
          'drawDocument': {
            'requestId': 'draw-1',
            'requestBillNo': 'DRAW-001',
            'lineCount': 1,
            'skippedSelfMade': const <String>[],
          },
        },
      ],
      'drawDocuments': [
        {
          'requestId': 'draw-1',
          'requestBillNo': 'DRAW-001',
          'lineCount': 1,
          'skippedSelfMade': const <String>[],
        },
      ],
    });

    expect(result.packageId, 'package-1');
    expect(result.purchaseRequest?.requestBillNo, 'PR-001');
    expect(result.subcontractApplication?.requestBillNo, 'SA-001');
    expect(result.drawDocuments.single.requestId, 'draw-1');
    expect(result.executionSegments.single.segmentCode, 'SEG-001');
    expect(result.executionSegments.single.status, 'READY');
    expect(
      result.executionSegments.single.materials.single.stockAllocatedQty,
      7.5,
    );
    expect(
      result.executionSegments.single.drawDocument?.requestBillNo,
      'DRAW-001',
    );
  });
}
