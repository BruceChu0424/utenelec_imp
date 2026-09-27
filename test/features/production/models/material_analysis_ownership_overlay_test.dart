import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/material_analysis_ownership_overlay.dart';
import 'package:uten_imp/features/production/models/material_preparation_supply_slice.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';

void main() {
  test(
    'only goods ownership changes across all occurrences; business facts stay current',
    () {
      final current = _current();
      final fresh = _view(
        version: 2,
        products: const [
          ProductionMaterialAnalysisProduct(
            analysisLineId: 'unrelated-source',
            goodsId: 'g',
            requestedQty: 999,
            latestPlanId: 'stale-plan',
            planExecutionResponsibleId: 'stale-worker',
          ),
        ],
        materials: const [
          ProductionMaterialAnalysisMaterial(
            materialLineId: 'read-side-row',
            goodsId: 'g',
            actionable: false,
            requiredQty: 999,
            sourceConfirmed: MaterialSupplyRoute.buy,
            owningWarehouseId: 'new-warehouse',
            owningWarehouseName: '新所属仓',
            owningWorkshopId: 'new-workshop',
            owningWorkshopName: '新归属车间',
          ),
        ],
      );
      final merged = current.withOwnershipFrom(fresh);
      expect(identical(merged, current), isFalse);
      expect(merged.analysisId, current.analysisId);
      expect(merged.version, 17);
      expect(merged.fingerprint, 'quantity-fingerprint');
      expect(merged.status, 'PARTIALLY_PLANNED');
      expect(merged.warehouseId, 'actual-stock-scope');
      expect(merged.warehouseIds, same(current.warehouseIds));
      expect(merged.supplyActions, same(current.supplyActions));
      expect(merged.allowedActions, same(current.allowedActions));
      expect(
        merged.planningBlockedReasons,
        same(current.planningBlockedReasons),
      );
      expect(
        merged.overproductionDefaults,
        same(current.overproductionDefaults),
      );
      expect(merged.analysisNo, current.analysisNo);
      expect(merged.fqcReplenishmentOnly, isTrue);
      expect(merged.fqcRecoveryAuthorizationId, 'recovery-proof');
      expect(merged.routeResetCount, 3);
      for (var i = 0; i < 2; i++) {
        final original = current.materials[i];
        final row = merged.materials[i];
        expect(row.owningWarehouseId, 'new-warehouse');
        expect(row.owningWarehouseName, '新所属仓');
        expect(row.owningWorkshopId, 'new-workshop');
        expect(row.owningWorkshopName, '新归属车间');
        expect(row.materialLineId, original.materialLineId);
        expect(row.analysisLineId, original.analysisLineId);
        expect(row.colorId, original.colorId);
        expect(row.nodeKey, original.nodeKey);
        expect(row.requiredQty, 11);
        expect(row.sourceRequiredQty, 12);
        expect(row.availableQty, 13);
        expect(row.exactPeggedQty, 14);
        expect(row.planningUncoveredQty, 15);
        expect(row.preparationSharedAvailableQty, 7000);
        expect(row.preparationOwnedAvailableQty, 1000);
        expect(row.preparationUncoveredBeforeSharedQty, 16);
        expect(row.preparationAdoptableSharedQty, 6999);
        expect(row.preparationAdoptedQty, 2);
        expect(row.preparationPoolKey, 'opaque-pool');
        expect(
          row.preparationSharedSupplySlices,
          same(original.preparationSharedSupplySlices),
        );
        expect(row.aggregatePreparation, same(original.aggregatePreparation));
        expect(row.notifiedTargets, same(original.notifiedTargets));
        expect(row.path, same(original.path));
        expect(row.routeConfirmed, isTrue);
        expect(row.sourceConfirmed, MaterialSupplyRoute.make);
        expect(row.sourceSuggestion, MaterialSupplyRoute.buy);
        expect(
          row.requirementState,
          MaterialRequirementState.delegatedToMakeChild,
        );
        expect(row.planAnchorAnalysisLineId, 'actual-anchor');
        expect(row.flowStage, 'MAKE_IN_PROGRESS');
        expect(row.actionable, isTrue);
      }
      expect(merged.materials.last, same(current.materials.last));
      final product = merged.products.single;
      final original = current.products.single;
      expect(product.owningWarehouseId, 'new-warehouse');
      expect(product.owningWorkshopId, 'new-workshop');
      expect(product.analysisLineId, original.analysisLineId);
      expect(product.sourceType, 'SALES_ORDER_ITEM');
      expect(product.sourceRef, 'source-reference');
      expect(product.salesOrderItemId, 'sales-item');
      expect(product.rootMaterialLineId, 'root-material');
      expect(product.requestedQty, 1000);
      expect(product.issuedPlanQty, 10000);
      expect(product.unitRate, 20);
      expect(product.latestPlanId, 'actual-plan');
      expect(product.latestPlanNo, 'SJ-actual');
      expect(product.planExecutionStatus, 'IN_PROGRESS');
      expect(product.planExecutionWorkshopId, 'actual-workshop');
      expect(product.planExecutionWorkshopName, '实际派工车间');
      expect(product.planExecutionResponsibleId, 'actual-worker');
      expect(product.planExecutionResponsibleName, '实际负责人');
      expect(current.materials.first.owningWarehouseId, 'old-warehouse');
      expect(current.products.single.owningWorkshopId, 'old-workshop');
      expect(() => merged.materials.clear(), throwsUnsupportedError);
      expect(() => merged.products.clear(), throwsUnsupportedError);
    },
  );

  test('product metadata supplies goods absent from fresh material rows', () {
    final merged = _current().withOwnershipFrom(
      _view(
        products: const [
          ProductionMaterialAnalysisProduct(
            analysisLineId: 'fresh-product',
            goodsId: 'g',
            owningWarehouseId: 'product-warehouse',
            owningWarehouseName: '产品所属仓',
            owningWorkshopId: 'product-workshop',
            owningWorkshopName: '产品归属车间',
          ),
        ],
      ),
    );
    expect(merged.products.single.owningWarehouseId, 'product-warehouse');
    expect(
      merged.materials.take(2).map((row) => row.owningWorkshopId),
      everyElement('product-workshop'),
    );
  });

  test('explicit null clears metadata without changing other values', () {
    final current = _current();
    final fresh = _view(
      materials: const [
        ProductionMaterialAnalysisMaterial(
          materialLineId: 'fresh',
          goodsId: 'g',
          actionable: false,
        ),
      ],
    );
    final merged = current.withOwnershipFrom(fresh);
    for (final row in merged.materials.take(2)) {
      expect(row.owningWarehouseId, isNull);
      expect(row.owningWarehouseName, isNull);
      expect(row.owningWorkshopId, isNull);
      expect(row.owningWorkshopName, isNull);
      expect(row.preparationOwnedAvailableQty, 1000);
    }
    expect(merged.products.single.owningWarehouseId, isNull);
    expect(merged.products.single.owningWorkshopName, isNull);
    expect(merged.withOwnershipFrom(fresh), same(merged));
  });

  test(
    'another analysis or missing goods leaves the exact current instance',
    () {
      final current = _current();
      expect(
        current.withOwnershipFrom(_view(analysisId: 'other')),
        same(current),
      );
      expect(current.withOwnershipFrom(_view()), same(current));
      expect(
        current.withOwnershipFrom(
          _view(
            materials: const [
              ProductionMaterialAnalysisMaterial(
                materialLineId: 'unknown',
                goodsId: 'not-present',
                actionable: false,
                owningWarehouseId: 'different',
              ),
            ],
          ),
        ),
        same(current),
      );
    },
  );

  test(
    'unchanged ownership does not publish different quantities or rebuild lists',
    () {
      final current = _current();
      final fresh = _view(
        version: 999,
        materials: const [
          ProductionMaterialAnalysisMaterial(
            materialLineId: 'fresh',
            goodsId: 'g',
            actionable: false,
            requiredQty: 999999,
            owningWarehouseId: 'old-warehouse',
            owningWarehouseName: '旧所属仓',
            owningWorkshopId: 'old-workshop',
            owningWorkshopName: '旧归属车间',
          ),
        ],
      );
      expect(current.withOwnershipFrom(fresh), same(current));
      expect(current.withOwnershipFrom(current), same(current));
    },
  );
}

ProductionMaterialAnalysisView _view({
  String analysisId = 'analysis',
  int version = 17,
  List<ProductionMaterialAnalysisMaterial> materials = const [],
  List<ProductionMaterialAnalysisProduct> products = const [],
}) => ProductionMaterialAnalysisView(
  analysisId: analysisId,
  version: version,
  fingerprint: 'quantity-fingerprint',
  materials: materials,
  products: products,
);

ProductionMaterialAnalysisView _current() => ProductionMaterialAnalysisView(
  analysisId: 'analysis',
  version: 17,
  fingerprint: 'quantity-fingerprint',
  status: 'PARTIALLY_PLANNED',
  warehouseId: 'actual-stock-scope',
  warehouseIds: const ['actual-stock-scope'],
  analyzedAt: '2026-09-26T00:00:00Z',
  allowedActions: const {'GENERATE_PLAN'},
  fqcReplenishmentOnly: true,
  fqcRecoveryAuthorizationId: 'recovery-proof',
  planningBlockedReasons: const {'other': 'blocked'},
  routeResetCount: 3,
  overproductionDefaults: const {'g': 0.2},
  analysisNo: 'WL-test',
  supplyActions: const [
    MaterialAnalysisSupplyAction(
      actionId: 'action',
      requestedQty: 3000,
      publicSurplusQty: 7000,
    ),
  ],
  materials: [
    _material('a', 'red'),
    _material('b', 'blue'),
    const ProductionMaterialAnalysisMaterial(
      materialLineId: 'other',
      goodsId: 'other-g',
      actionable: false,
    ),
  ],
  products: const [
    ProductionMaterialAnalysisProduct(
      analysisLineId: 'source-product',
      rootMaterialLineId: 'root-material',
      sourceType: 'SALES_ORDER_ITEM',
      sourceRef: 'source-reference',
      salesOrderItemId: 'sales-item',
      goodsId: 'g',
      unitRate: 20,
      requestedQty: 1000,
      issuedPlanQty: 10000,
      latestPlanId: 'actual-plan',
      latestPlanNo: 'SJ-actual',
      planExecutionStatus: 'IN_PROGRESS',
      planExecutionWorkshopId: 'actual-workshop',
      planExecutionWorkshopName: '实际派工车间',
      planExecutionResponsibleId: 'actual-worker',
      planExecutionResponsibleName: '实际负责人',
      owningWarehouseId: 'old-warehouse',
      owningWarehouseName: '旧所属仓',
      owningWorkshopId: 'old-workshop',
      owningWorkshopName: '旧归属车间',
    ),
  ],
);

ProductionMaterialAnalysisMaterial _material(String id, String color) =>
    ProductionMaterialAnalysisMaterial(
      materialLineId: id,
      analysisLineId: 'source-$id',
      nodeKey: 'edge/$id',
      goodsId: 'g',
      colorId: color,
      actionable: true,
      requiredQty: 11,
      sourceRequiredQty: 12,
      availableQty: 13,
      exactPeggedQty: 14,
      planningUncoveredQty: 15,
      preparationUncoveredBeforeSharedQty: 16,
      preparationSharedAvailableQty: 7000,
      preparationOwnedAvailableQty: 1000,
      preparationAdoptableSharedQty: 6999,
      preparationAdoptedQty: 2,
      preparationPoolKey: 'opaque-pool',
      preparationSharedSupplySlices: const [
        MaterialPreparationSupplySlice(
          key: 'opaque-slice',
          availableQty: 7000,
          adoptable: true,
        ),
      ],
      aggregatePreparation: const MaterialAggregatePreparation(
        requiredQty: 11,
        orderedQty: 10000,
        allocatedOrderedQty: 1000,
        totalOrderedQty: 10000,
        orderedQtyExact: true,
        planningUncoveredQty: 15,
        netShortageQty: 0,
        targetMaterialLineIds: ['canonical-a', 'canonical-b'],
        actionable: true,
      ),
      notifiedTargets: const [
        MaterialAnalysisNotificationTarget(
          target: MaterialSupplyRoute.make,
          actionId: 'action',
          documentId: 'actual-plan',
          allocatedQty: 1000,
          notificationReversalPending: true,
        ),
      ],
      sourceConfirmed: MaterialSupplyRoute.make,
      sourceSuggestion: MaterialSupplyRoute.buy,
      routeConfirmed: true,
      requirementState: MaterialRequirementState.delegatedToMakeChild,
      planAnchorAnalysisLineId: 'actual-anchor',
      path: const ['父件', '子件'],
      flowStage: 'MAKE_IN_PROGRESS',
      owningWarehouseId: 'old-warehouse',
      owningWarehouseName: '旧所属仓',
      owningWorkshopId: 'old-workshop',
      owningWorkshopName: '旧归属车间',
    );
