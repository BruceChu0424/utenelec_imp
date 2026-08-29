import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/production_execution_planning.dart';

void main() {
  test(
    'formats persisted four-decimal planning quantities without hiding them',
    () {
      expect(formatProductionPlanningQuantity(0.0001), '0.0001');
      expect(formatProductionPlanningQuantity(1.2300), '1.23');
      expect(formatProductionPlanningQuantity(1000), '1000');
      expect(formatProductionPlanningUsage(0.000001), '0.000001');
      expect(isValidProductionPlanningQuantityText('1.2345'), isTrue);
      expect(isValidProductionPlanningQuantityText('.0001'), isTrue);
      expect(isValidProductionPlanningQuantityText('1.23456'), isFalse);
      expect(isValidProductionPlanningQuantityText('1e-4'), isFalse);
    },
  );

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
          'productSpec': 'M8 x 30',
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
              'requirementMode': 'EXACT_SNAPSHOT',
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
      preview.executionSegments.single.materialRequirementMode,
      'DEMANDED',
    );
    expect(preview.executionSegments.single.productSpec, 'M8 x 30');
    expect(
      preview.executionSegments.single.materials.single.perProductQty,
      1.25,
    );
    expect(
      preview.executionSegments.single.materials.single.requirementMode,
      'EXACT_SNAPSHOT',
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
          'deferUntilManualRelease': false,
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
    expect(result.executionSegments.single.materialRequirementMode, 'DEMANDED');
    expect(
      result.executionSegments.single.materials.single.stockAllocatedQty,
      7.5,
    );
    expect(
      result.executionSegments.single.materials.single.requirementMode,
      'LINEAR',
    );
    expect(
      result.executionSegments.single.drawDocument?.requestBillNo,
      'DRAW-001',
    );
  });

  test('exact grouped usage is sum required over sum segment product qty', () {
    const ready = ProductionExecutionMaterialPreview(
      goodsId: 'material-1',
      unitId: 'unit-1',
      perProductQty: 0.333334,
      requiredQty: 2,
      availableBeforeQty: 2,
      candidateAllocatedQty: 2,
      shortageQty: 0,
      supplyRoute: 'BUY',
      requirementMode: 'EXACT_SNAPSHOT',
    );
    const waiting = ProductionExecutionMaterialPreview(
      goodsId: 'material-1',
      unitId: 'unit-1',
      perProductQty: 0.5,
      requiredQty: 2,
      availableBeforeQty: 0,
      candidateAllocatedQty: 0,
      shortageQty: 2,
      supplyRoute: 'BUY',
      requirementMode: 'EXACT_SNAPSHOT',
    );

    expect(
      aggregateProductionPlanningMaterialUsage([ready, waiting], 6 + 4),
      closeTo(0.4, 0.0000001),
    );
    expect(
      formatProductionPlanningGroupedMaterialUsage('EXACT_SNAPSHOT', 0.4),
      '按包/批(分段合计均耗) 0.4',
    );
    expect(
      formatProductionPlanningGroupedMaterialUsage('LINEAR', 0.4),
      '单台用量 0.4',
    );

    const largeTail = ProductionExecutionMaterialPreview(
      goodsId: 'material-2',
      unitId: 'unit-1',
      perProductQty: 0.000301,
      requiredQty: 3,
      availableBeforeQty: 3,
      candidateAllocatedQty: 3,
      shortageQty: 0,
      supplyRoute: 'BUY',
      requirementMode: 'EXACT_SNAPSHOT',
    );
    expect(largeTail.perProductQty * 9999, isNot(closeTo(3, 0.0000001)));
    expect(largeTail.requiredQty, 3);
  });

  test('zero-material reasons have explicit staff-facing explanations', () {
    expect(
      productionZeroMaterialReasonText('ZERO_MATERIAL', 'DIRECT_MAKE'),
      '无需生产领料：直接自制',
    );
    expect(
      productionZeroMaterialReasonText('ZERO_MATERIAL', 'PLAN_BOM_OVERRIDE'),
      '无需生产领料：本计划 BOM 例外',
    );
    expect(
      productionZeroMaterialReasonText(
        'ZERO_MATERIAL',
        'NO_PRODUCTION_HARD_GATE',
      ),
      '无需生产领料：仅发货或参考物料',
    );
    expect(productionZeroMaterialReasonText('DEMANDED', null), isNull);
  });

  test('decodes a persisted planning draft view', () {
    final draft = ProductionPlanningDraftView.fromJson({
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
        'warehouseId': 'warehouse-1',
        'idempotencyKey': 'planning-plan-1-draft-1',
        'previewFingerprint': 'a' * 64,
        'generatePurchaseRequest': true,
        'routes': [
          {'goodsId': 'material-1', 'colorId': 'color-1', 'supplyRoute': 'BUY'},
        ],
        'items': const <Map<String, dynamic>>[],
        'segments': [
          {
            'clientSegmentKey': 'line-1-waiting',
            'sourcePlanItemId': 'plan-item-1',
            'requestedStatus': 'WAITING',
            'deferUntilManualRelease': true,
            'plannedQty': 3.25,
            'workshopDepartmentId': 'workshop-1',
            'teamDepartmentId': 'team-1',
            'responsibleEmployeeId': 'employee-1',
            'planBeginDate': '2026-08-03',
            'planEndDate': '2026-08-04',
            'bomFingerprint': 'b' * 64,
          },
        ],
      },
    });

    expect(draft.draftId, 'draft-1');
    expect(draft.status, 'ACTIVE');
    expect(draft.segmentCount, 1);
    expect(draft.generatePurchaseRequest, isTrue);
    expect(draft.routes.single.goodsId, 'material-1');
    expect(draft.routes.single.colorId, 'color-1');
    expect(draft.routes.single.supplyRoute, 'BUY');
    expect(draft.plannedBy, 'user-1');
    expect(draft.segments.single.clientSegmentKey, 'line-1-waiting');
    expect(draft.segments.single.plannedQty, 3.25);
    expect(draft.segments.single.deferUntilManualRelease, isTrue);
    expect(draft.segments.single.workshopDepartmentId, 'workshop-1');
    expect(draft.segments.single.responsibleEmployeeId, 'employee-1');
  });

  test('submits explicit routes only for BUY and SUBCONTRACT shortages', () {
    final preview = _preview(
      directMaterials: const [
        ProductionExecutionMaterialPreview(
          goodsId: 'buy',
          unitId: 'unit',
          perProductQty: 1,
          requiredQty: 3,
          availableBeforeQty: 0,
          candidateAllocatedQty: 0,
          shortageQty: 3,
          supplyRoute: 'BUY',
        ),
        ProductionExecutionMaterialPreview(
          goodsId: 'subcontract',
          unitId: 'unit',
          perProductQty: 1,
          requiredQty: 2,
          availableBeforeQty: 0,
          candidateAllocatedQty: 0,
          shortageQty: 2,
          supplyRoute: 'SUBCONTRACT',
        ),
        ProductionExecutionMaterialPreview(
          goodsId: 'make',
          unitId: 'unit',
          perProductQty: 1,
          requiredQty: 4,
          availableBeforeQty: 0,
          candidateAllocatedQty: 0,
          shortageQty: 4,
          supplyRoute: 'MAKE',
        ),
        ProductionExecutionMaterialPreview(
          goodsId: 'covered-buy',
          unitId: 'unit',
          perProductQty: 1,
          requiredQty: 1,
          availableBeforeQty: 1,
          candidateAllocatedQty: 1,
          shortageQty: 0,
          supplyRoute: 'BUY',
        ),
        ProductionExecutionMaterialPreview(
          goodsId: 'small-buy',
          unitId: 'unit',
          perProductQty: 0.0001,
          requiredQty: 0.0001,
          availableBeforeQty: 0,
          candidateAllocatedQty: 0,
          shortageQty: 0.0001,
          supplyRoute: 'BUY',
        ),
      ],
    );

    final routes = buildProductionMaterialSupplyRoutes(
      preview.executionSegments,
    );

    expect(routes.map((route) => '${route.goodsId}:${route.supplyRoute}'), [
      'buy:BUY',
      'subcontract:SUBCONTRACT',
      'small-buy:BUY',
    ]);
  });

  test('material review excludes recursively exploded lower-level goods', () {
    final preview = _preview(
      recursiveMaterials: const [
        ProductionPlanningMaterial(
          goodsId: 'direct-make',
          goodsCode: 'B',
          goodsName: 'Direct child',
          selfMade: true,
          sourceType: '??',
        ),
        ProductionPlanningMaterial(
          goodsId: 'lower-level-buy',
          goodsCode: 'C',
          goodsName: 'Nested purchase',
          sourceType: '??',
        ),
      ],
      directMaterials: const [
        ProductionExecutionMaterialPreview(
          goodsId: 'direct-make',
          unitId: 'unit',
          perProductQty: 1,
          requiredQty: 2,
          availableBeforeQty: 0,
          candidateAllocatedQty: 0,
          shortageQty: 2,
          supplyRoute: 'MAKE',
        ),
        ProductionExecutionMaterialPreview(
          goodsId: 'direct-make',
          unitId: 'unit',
          perProductQty: 1,
          requiredQty: 3,
          availableBeforeQty: 0,
          candidateAllocatedQty: 0,
          shortageQty: 3,
          supplyRoute: 'MAKE',
        ),
      ],
    );

    final reviewMaterials = buildProductionDirectReviewMaterials(preview);

    expect(reviewMaterials, hasLength(1));
    expect(reviewMaterials.single.goodsId, 'direct-make');
    expect(reviewMaterials.single.gross, 5);
    expect(reviewMaterials.single.timelyShortage, 5);
    expect(preview.hasBlockingBomGaps, isFalse);
  });

  test('MAKE leaf without lower BOM does not block planning', () {
    // 自制叶子件（无下层 BOM，原料走车间领料）缺料合法：派生「造 N 个」裸子计划，不再拦截。
    final preview = _preview(
      recursiveMaterials: const [
        ProductionPlanningMaterial(
          goodsId: 'make-without-bom',
          sourceType: '自制',
        ),
      ],
      directMaterials: const [
        ProductionExecutionMaterialPreview(
          goodsId: 'make-without-bom',
          unitId: 'unit',
          perProductQty: 1,
          requiredQty: 5,
          availableBeforeQty: 0,
          candidateAllocatedQty: 0,
          shortageQty: 5,
          supplyRoute: 'MAKE',
        ),
      ],
    );
    final unknownMake = _preview(
      directMaterials: const [
        ProductionExecutionMaterialPreview(
          goodsId: 'unknown-make',
          unitId: 'unit',
          perProductQty: 1,
          requiredQty: 1,
          availableBeforeQty: 0,
          candidateAllocatedQty: 0,
          shortageQty: 0.0001,
          supplyRoute: 'MAKE',
        ),
      ],
    );

    expect(preview.hasBlockingBomGaps, isFalse);
    expect(unknownMake.hasBlockingBomGaps, isFalse);
  });
}

ProductionPlanningPreview _preview({
  List<ProductionPlanningMaterial> recursiveMaterials = const [],
  List<ProductionExecutionMaterialPreview> directMaterials = const [],
  List<String> noBomPlanItemIds = const [],
}) {
  return ProductionPlanningPreview(
    planId: 'plan-1',
    warehouseId: 'warehouse-1',
    fingerprint: 'a' * 64,
    balancedKitCoverage: false,
    executionSegmentationReady: true,
    materials: recursiveMaterials,
    noBomPlanItemIds: noBomPlanItemIds,
    executionSegments: [
      ProductionExecutionSegmentPreview(
        clientSegmentKey: 'segment-preview-1',
        sourcePlanItemId: 'plan-item-1',
        productGoodsId: 'product-1',
        plannedQty: 5,
        suggestedStatus: 'WAITING',
        bomFingerprint: 'b' * 64,
        materials: directMaterials,
      ),
    ],
  );
}
