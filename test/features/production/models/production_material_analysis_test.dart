import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';

void main() {
  test('legacy leaf figures do not invent a main warehouse safety budget', () {
    final material = ProductionMaterialAnalysisMaterial.fromJson({
      'materialLineId': 'legacy',
      'warehouseBreakdown': [
        {
          'warehouseId': 'leaf',
          'publicAvailableQty': 200,
          'openSafetySupplyQty': 30,
          'safetyReplenishmentGapQty': 99,
        },
      ],
    });
    expect(material.mainWarehousePublicAvailableQty, 0);
    expect(material.mainWarehouseOpenSafetySupplyQty, 0);
    expect(material.mainWarehouseSafetyReplenishmentGapQty, 0);
    expect(material.warehouseStocks.single.safetyReplenishmentGapQty, 99);
  });

  test(
    'historical notification responses do not offer reversal reconciliation',
    () {
      final historical = MaterialAnalysisNotificationTarget.fromJson({
        'route': 'SUBCONTRACT',
        'status': 'CANCELLED',
      });
      final pending = MaterialAnalysisNotificationTarget.fromJson({
        'route': 'SUBCONTRACT',
        'status': 'CANCELLED',
        'notificationReversalPending': true,
      });
      expect(historical.notificationReversalPending, isFalse);
      expect(pending.notificationReversalPending, isTrue);
    },
  );

  test('parses the frozen flat-tree and product BOM contract tolerantly', () {
    final view = ProductionMaterialAnalysisView.fromJson({
      'analysisId': 'analysis-1',
      'status': 'ANALYZED',
      'version': 4,
      'fingerprint': 'a' * 64,
      'warehouseId': 'warehouse-1',
      'allowedActions': ['PLAN_PREVIEW', 'GENERATE_AND_APPROVE'],
      'products': [
        {
          'analysisLineId': 'product-line-1',
          'sourceType': 'SALES_ORDER',
          'sourceRef': 'XS-20260808-001',
          'sourceReason': '销售履约',
          'salesOrderNo': 'XS-001',
          'salesOrderId': 'order-1',
          'goodsName': '组装产品',
          'unitRate': 1.5,
          'requestedQty': 100,
          'submittedQty': 10,
          'approvedQty': 5,
          'remainingQty': 95,
          'readyNowQty': 10,
          'readyStartQty': 20,
          'readyFinishQty': 10,
          'readyShipQty': 8,
          'readyByDateQty': 40,
          'readinessRatio': 25,
          'hasProductionMaterialChildren': true,
          'allocationPriority': 2,
          'planExecutionStatus': 'IN_PROGRESS',
          'latestPlanId': 'plan-1',
          'latestPlanNo': 'SC26080001',
          'planExecutionPlannedQty': '10.0000',
          'planExecutionInboundQty': 2.5,
          'planExecutionProgressRatio': 0.25,
        },
      ],
      'flatMaterials': [
        {
          'materialLineId': 'material-line-1',
          'analysisLineId': 'product-line-1',
          'planAnchorAnalysisLineId': 'plan-child-item-uuid',
          'nodeKey': 'node-1',
          'actionGroupKey': 'action-material-1',
          'materialKey': 'goods-1|color-1|unit-1',
          'goodsId': 'goods-1',
          'goodsName': '共享紧固件',
          'level': 3,
          'path': ['产品', '组件A', '共享紧固件'],
          'parentNodeKey': 'node-parent',
          'parentGoodsId': 'goods-parent',
          'parentLabel': 'C-A · 组件A',
          'perProductQty': 2,
          'requiredQty': 20,
          'availableQty': 4,
          'allocatedAvailableQty': 3,
          'exactPeggedQty': 2,
          'safetyStockQty': 8,
          'mainWarehousePublicAvailableQty': 10,
          'mainWarehouseOpenSafetySupplyQty': 2,
          'mainWarehouseSafetyReplenishmentGapQty': 0,
          'shortageQty': 16,
          'demandSupplyGapQty': 17,
          'sourceSuggestion': 'BUY',
          'sourceConfirmed': null,
          'routeConfirmed': false,
          'controlStage': 'SHIP',
          'consumptionBasis': 'PER_PACKAGE',
          'basisOutputQty': 12,
          'allowPartialPackage': true,
          'hardGate': true,
          'warehouseBreakdown': [
            {
              'warehouseId': 'warehouse-1',
              'warehouseCode': 'WH-01',
              'warehouseName': '主仓',
              'onHandQty': 9,
              'reservedQty': 1,
              'availableQty': 6,
              'ownPeggedQty': 2,
              'publicAvailableQty': 4,
              'openSafetySupplyQty': 1,
              'safetyReplenishmentGapQty': 3,
            },
          ],
          'downstreamReferences': [
            {
              'route': 'BUY',
              'documentType': 'PURCHASE_REQUEST',
              'documentId': 'request-1',
              'documentNo': 'PR-1',
              'status': 'OPEN',
            },
          ],
        },
      ],
      'supplyActions': [
        {
          'actionId': 'action-1',
          'actionGroupKey': 'action-material-1',
          'generation': 2,
          'route': 'BUY',
          'status': 'IN_PROGRESS',
          'requestedQty': 7,
          'safetyReplenishmentQty': 3,
          'totalRequestedQty': 10,
          'safetyStockSnapshotQty': 8,
          'publicAvailableSnapshotQty': 4,
          'openSafetySupplySnapshotQty': 1,
          'documentNo': 'PR-1',
        },
      ],
    });

    expect(view.allowedActions, contains('GENERATE_AND_APPROVE'));
    expect(view.products.single.readinessRatio, 0.25);
    expect(view.products.single.hasProductionMaterialChildren, isTrue);
    expect(view.products.single.readyStartQty, 20);
    expect(view.products.single.readyFinishQty, 10);
    expect(view.products.single.readyShipQty, 8);
    expect(view.products.single.approvedQty, 5);
    expect(view.products.single.unitRate, 1.5);
    expect(view.products.single.sourceRef, 'XS-20260808-001');
    expect(view.products.single.sourceReason, '销售履约');
    expect(view.products.single.orderNo, 'XS-001');
    expect(view.products.single.allocationPriority, 2);
    expect(view.products.single.planExecutionStatus, 'IN_PROGRESS');
    expect(view.products.single.latestPlanId, 'plan-1');
    expect(view.products.single.latestPlanNo, 'SC26080001');
    expect(view.products.single.planExecutionPlannedQty, 10);
    expect(view.products.single.planExecutionInboundQty, 2.5);
    expect(view.products.single.planExecutionProgressRatio, 0.25);
    expect(
      ProductionMaterialAnalysisProduct.fromJson({
        'analysisLineId': 'legacy-product',
        'planExecutionStatus': 'IN_PROGRESS',
      }).planExecutionProgressRatio,
      isNull,
    );
    final material = view.materials.single;
    expect(material.planAnchorAnalysisLineId, 'plan-child-item-uuid');
    expect(material.actionGroupKey, 'action-material-1');
    expect(material.path, ['产品', '组件A', '共享紧固件']);
    expect(material.parentNodeKey, 'node-parent');
    expect(material.parentLabel, 'C-A · 组件A');
    expect(material.perProductQty, 2);
    expect(material.availableQty, 4);
    expect(material.allocatedAvailableQty, 3);
    expect(material.exactPeggedQty, 2);
    expect(material.mainWarehousePublicAvailableQty, 10);
    expect(material.mainWarehouseOpenSafetySupplyQty, 2);
    expect(material.mainWarehouseSafetyReplenishmentGapQty, 0);
    expect(material.demandSupplyGapQty, 17);
    expect(material.actionable, isFalse);
    expect(material.sourceSuggestion, MaterialSupplyRoute.buy);
    expect(material.confirmedRoute, isNull);
    expect(material.controlStage, 'SHIP');
    expect(material.consumptionBasis, 'PER_PACKAGE');
    expect(material.basisOutputQty, 12);
    expect(material.allowPartialPackage, isTrue);
    expect(material.hardGate, isTrue);
    expect(material.warehouseStocks.single.ownPeggedQty, 2);
    expect(material.warehouseStocks.single.publicAvailableQty, 4);
    expect(material.warehouseStocks.single.openSafetySupplyQty, 1);
    expect(material.warehouseStocks.single.safetyReplenishmentGapQty, 3);
    expect(material.notifiedTargets.single.documentNo, 'PR-1');
    final action = view.supplyActions.single;
    expect(action.route, MaterialSupplyRoute.buy);
    expect(action.requestedQty, 7);
    expect(action.safetyReplenishmentQty, 3);
    expect(action.totalRequestedQty, 10);
    expect(action.safetyStockSnapshotQty, 8);
    expect(action.publicAvailableSnapshotQty, 4);
    expect(action.openSafetySupplySnapshotQty, 1);
  });

  test('supply quantity always serializes the explicit safety slice', () {
    const input = MaterialSupplyQuantityInput(
      actionGroupKey: 'group-1',
      qty: 0,
      safetyReplenishmentQty: 6,
    );

    expect(input.toJson(), {
      'actionGroupKey': 'group-1',
      'qty': 0.0,
      'safetyReplenishmentQty': 6.0,
      'publicExtraQty': 0.0,
    });
  });

  test('missing actionable defaults to level one only', () {
    final view = ProductionMaterialAnalysisView.fromJson({
      'analysisId': 'analysis-2',
      'version': 1,
      'fingerprint': 'f',
      'products': <Map<String, dynamic>>[],
      'flatMaterials': [
        {'materialLineId': 'level-1', 'level': 1},
        {'materialLineId': 'level-2', 'level': 2},
      ],
    });

    expect(view.materials[0].actionable, isTrue);
    expect(view.materials[1].actionable, isFalse);
  });

  test('parses analysis history rows and tolerates missing newer fields', () {
    final item = MaterialAnalysisListItem.fromJson({
      'analysisId': 'analysis-1',
      'status': 'PARTIALLY_PLANNED',
      'version': 8,
      'warehouseCode': 'WH-01',
      'warehouseName': '主仓',
      'analyzedAt': '2026-08-08T08:00:00Z',
      'makerName': '生产调度员',
      'sourceCount': 2,
      'sourceTypes': ['SALES_ORDER', 'REWORK'],
      'sourceRefs': ['XS-001', 'RW-001'],
      'productLabels': ['P-01 产品一', 'P-02 产品二'],
      'requestedQty': 100,
      'submittedQty': 10,
      'approvedQty': 5,
      'remainingQty': 85,
      'readyNowQty': 12,
      'readyByDateQty': 30,
    });

    expect(item.status, 'PARTIALLY_PLANNED');
    expect(item.updatedAt, item.analyzedAt);
    expect(item.sourceRefs, ['XS-001', 'RW-001']);
    expect(item.readyNowQty, 12);
    expect(item.readyByDateQty, 30);
  });

  test('serializes sales and manual sources without bypass fields', () {
    const sales = MaterialAnalysisSourceInput(
      salesOrderItemId: 'sales-line-1',
      requestedQty: 8,
    );
    const manual = MaterialAnalysisSourceInput(
      sourceType: 'REWORK',
      sourceRef: 'RW-20260808-001',
      goodsId: 'goods-1',
      colorId: 'color-1',
      unitId: 'unit-1',
      requestedQty: 3,
      sourceReason: '客诉返工',
      deliveryDate: '2026-08-20',
    );

    expect(sales.toJson(), {
      'salesOrderItemId': 'sales-line-1',
      'requestedQty': 8.0,
    });
    expect(manual.toJson(), {
      'sourceType': 'REWORK',
      'sourceRef': 'RW-20260808-001',
      'goodsId': 'goods-1',
      'colorId': 'color-1',
      'unitId': 'unit-1',
      'requestedQty': 3.0,
      'sourceReason': '客诉返工',
      'deliveryDate': '2026-08-20',
    });
    expect(
      manual.canonicalKey,
      'REWORK|RW-20260808-001|goods-1|color-1|unit-1',
    );
  });

  test('route decisions prefer one server action group', () {
    const decision = MaterialRouteDecision(
      actionGroupKey: 'action-material-1',
      route: MaterialSupplyRoute.make,
      reason: '交期要求改为自制',
    );

    expect(decision.toJson(), {
      'actionGroupKey': 'action-material-1',
      'route': 'MAKE',
      'reason': '交期要求改为自制',
    });
  });

  test('parses cross-plan reallocation and priority replenishment lineage', () {
    final view = ProductionMaterialAnalysisView.fromJson({
      'analysisId': 'source-analysis',
      'version': 9,
      'fingerprint': 'a' * 64,
      'flatMaterials': [
        {
          'materialLineId': 'source-material',
          'level': 1,
          'actionable': true,
          'crossReallocatedInQty': 0,
          'crossReallocatedOutQty': 4,
          'priorityPendingQty': 1.5,
          'priorityFulfilledQty': 2.5,
          'crossReallocationRefs': [
            {
              'reallocationId': 'allocation-1',
              'direction': 'OUT',
              'status': 'ACTIVE',
              'counterpartAnalysisId': 'target-analysis',
              'counterpartVersion': 6,
              'counterpartFingerprint': 'b' * 64,
              'counterpartMaterialLineId': 'target-material',
              'counterpartAnalysisLabel': '订单 XS-002',
              'counterpartProduct': '加急产品',
              'qty': 4,
              'currentEffectiveQty': 3.5,
              'priorityFulfilledQty': 2.5,
              'priorityOpenQty': 1.5,
              'reason': '客户加急',
              'canRevoke': false,
              'revokeBlockedReason': '接受计划已领料',
              'replenishmentRefs': [
                {
                  'route': 'SUBCONTRACT',
                  'sourceDocumentId': 'subcontract-1',
                  'sourceDocumentNo': 'WW-001',
                  'receiptNo': 'WR-001',
                  'qty': 2.5,
                },
              ],
            },
          ],
        },
      ],
    });

    final material = view.materials.single;
    final allocation = material.crossReallocationRefs.single;
    expect(material.crossReallocatedOutQty, 4);
    expect(material.priorityPendingQty, 1.5);
    expect(material.priorityFulfilledQty, 2.5);
    expect(allocation.isOutbound, isTrue);
    expect(allocation.id, 'allocation-1');
    expect(allocation.counterpartMaterialLineId, 'target-material');
    expect(allocation.counterpartVersion, 6);
    expect(allocation.currentEffectiveQty, 3.5);
    expect(allocation.canRevoke, isFalse);
    expect(allocation.revokeBlockedReason, '接受计划已领料');
    expect(
      allocation.replenishmentRefs.single.displayLabel,
      '委外回厂 2.5 · WW-001 / WR-001',
    );
  });

  test('cross-plan candidate parses target CAS aliases and safe label', () {
    final candidate = MaterialCrossReallocationCandidate.fromJson({
      'analysisId': 'target-analysis-123456',
      'version': 7,
      'fingerprint': 'c' * 64,
      'materialLineId': 'target-material',
      'sourceRefs': ['XS-20260821-001'],
      'productLabel': 'P-02 加急产品',
      'warehouseName': '主仓',
      'shortageQty': 5,
      'sourceLendableQty': 3.5,
    });

    expect(candidate.targetAnalysisId, 'target-analysis-123456');
    expect(candidate.targetVersion, 7);
    expect(candidate.targetMaterialLineId, 'target-material');
    expect(candidate.displayAnalysisLabel, 'XS-20260821-001');
    expect(candidate.shortageQty, 5);
    expect(candidate.sourceLendableQty, 3.5);
  });
}
