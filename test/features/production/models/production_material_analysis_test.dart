import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';

void main() {
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
          'productionBomPolicy': 'BOM_REQUIRED',
          'missingBom': true,
          'bomOverrideRequired': true,
          'hasActiveBom': false,
          'allocationPriority': 2,
          'planExecutionStatus': 'IN_PROGRESS',
          'latestPlanId': 'plan-1',
          'latestPlanNo': 'SC26080001',
        },
      ],
      'flatMaterials': [
        {
          'materialLineId': 'material-line-1',
          'analysisLineId': 'product-line-1',
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
          'shortageQty': 16,
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
    });

    expect(view.allowedActions, contains('GENERATE_AND_APPROVE'));
    expect(view.products.single.readinessRatio, 0.25);
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
    expect(view.products.single.hasBomPolicyError, isTrue);
    final material = view.materials.single;
    expect(material.actionGroupKey, 'action-material-1');
    expect(material.path, ['产品', '组件A', '共享紧固件']);
    expect(material.parentNodeKey, 'node-parent');
    expect(material.parentLabel, 'C-A · 组件A');
    expect(material.perProductQty, 2);
    expect(material.availableQty, 4);
    expect(material.allocatedAvailableQty, 3);
    expect(material.exactPeggedQty, 2);
    expect(material.actionable, isFalse);
    expect(material.sourceSuggestion, MaterialSupplyRoute.buy);
    expect(material.confirmedRoute, isNull);
    expect(material.controlStage, 'SHIP');
    expect(material.consumptionBasis, 'PER_PACKAGE');
    expect(material.basisOutputQty, 12);
    expect(material.allowPartialPackage, isTrue);
    expect(material.hardGate, isTrue);
    expect(material.warehouseStocks.single.ownPeggedQty, 2);
    expect(material.notifiedTargets.single.documentNo, 'PR-1');
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
}
