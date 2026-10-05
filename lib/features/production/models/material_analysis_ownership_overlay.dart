import 'production_material_analysis.dart';

/// Merges only the four goods master ownership fields from an authoritative DTO.
/// Callers determine read freshness; analysis quantity/version/plan facts are untouched.
extension MaterialAnalysisOwnershipOverlay on ProductionMaterialAnalysisView {
  ProductionMaterialAnalysisView withOwnershipFrom(
    ProductionMaterialAnalysisView fresh,
  ) {
    if (analysisId != fresh.analysisId || identical(this, fresh)) return this;
    final owners = <String, _Ownership>{};
    // Materials are the primary projection; products supply goods absent from that list.
    for (final material in fresh.materials) {
      final goods = material.goodsId;
      if (goods != null && goods.isNotEmpty) {
        owners.putIfAbsent(
          goods,
          () => _Ownership(
            material.owningWarehouseId,
            material.owningWarehouseName,
            material.owningWorkshopId,
            material.owningWorkshopName,
          ),
        );
      }
    }
    for (final product in fresh.products) {
      final goods = product.goodsId;
      if (goods != null && goods.isNotEmpty) {
        owners.putIfAbsent(
          goods,
          () => _Ownership(
            product.owningWarehouseId,
            product.owningWarehouseName,
            product.owningWorkshopId,
            product.owningWorkshopName,
          ),
        );
      }
    }
    List<ProductionMaterialAnalysisMaterial>? nextMaterials;
    for (var index = 0; index < materials.length; index++) {
      final current = materials[index];
      final owner = owners[current.goodsId];
      if (owner == null ||
          owner.matches(
            current.owningWarehouseId,
            current.owningWarehouseName,
            current.owningWorkshopId,
            current.owningWorkshopName,
          )) {
        continue;
      }
      nextMaterials ??= List.of(materials);
      nextMaterials[index] = _materialWithOwnership(current, owner);
    }
    List<ProductionMaterialAnalysisProduct>? nextProducts;
    for (var index = 0; index < products.length; index++) {
      final current = products[index];
      final owner = owners[current.goodsId];
      if (owner == null ||
          owner.matches(
            current.owningWarehouseId,
            current.owningWarehouseName,
            current.owningWorkshopId,
            current.owningWorkshopName,
          )) {
        continue;
      }
      nextProducts ??= List.of(products);
      nextProducts[index] = _productWithOwnership(current, owner);
    }
    if (nextMaterials == null && nextProducts == null) return this;
    return ProductionMaterialAnalysisView(
      analysisId: analysisId,
      version: version,
      fingerprint: fingerprint,
      status: status,
      warehouseId: warehouseId,
      warehouseIds: warehouseIds,
      analyzedAt: analyzedAt,
      products: nextProducts == null
          ? products
          : List.unmodifiable(nextProducts),
      materials: nextMaterials == null
          ? materials
          : List.unmodifiable(nextMaterials),
      warehouses: warehouses,
      supplyActions: supplyActions,
      allowedActions: allowedActions,
      fqcReplenishmentOnly: fqcReplenishmentOnly,
      fqcRecoveryAuthorizationId: fqcRecoveryAuthorizationId,
      planningBlockedReasons: planningBlockedReasons,
      routeResetCount: routeResetCount,
      autoConfirmedRouteCount: autoConfirmedRouteCount,
      pendingAutoConfirmRouteCount: pendingAutoConfirmRouteCount,
      overproductionDefaults: overproductionDefaults,
      analysisNo: analysisNo,
    );
  }
}

class _Ownership {
  const _Ownership(
    this.warehouseId,
    this.warehouseName,
    this.workshopId,
    this.workshopName,
  );
  final String? warehouseId;
  final String? warehouseName;
  final String? workshopId;
  final String? workshopName;
  bool matches(
    String? warehouse,
    String? warehouseLabel,
    String? workshop,
    String? workshopLabel,
  ) =>
      warehouseId == warehouse &&
      warehouseName == warehouseLabel &&
      workshopId == workshop &&
      workshopName == workshopLabel;
}

// Metadata-only clones. Every constructor field is forwarded deliberately, including
// private supply proofs and actual plan assignments. Keep this list complete when models grow.
ProductionMaterialAnalysisMaterial _materialWithOwnership(
  ProductionMaterialAnalysisMaterial current,
  _Ownership owner,
) => ProductionMaterialAnalysisMaterial(
  materialLineId: current.materialLineId,
  analysisLineId: current.analysisLineId,
  nodeKey: current.nodeKey,
  goodsId: current.goodsId,
  goodsCode: current.goodsCode,
  goodsName: current.goodsName,
  spec: current.spec,
  colorId: current.colorId,
  colorName: current.colorName,
  unitId: current.unitId,
  unitName: current.unitName,
  level: current.level,
  nodeRole: current.nodeRole,
  path: current.path,
  parentGoodsId: current.parentGoodsId,
  parentNodeKey: current.parentNodeKey,
  parentLabel: current.parentLabel,
  actionGroupKey: current.actionGroupKey,
  materialKey: current.materialKey,
  requiredQty: current.requiredQty,
  sourceRequiredQty: current.sourceRequiredQty,
  perProductQty: current.perProductQty,
  bomQty: current.bomQty,
  designBomQty: current.designBomQty,
  actualBomQty: current.actualBomQty,
  usageBasis: current.usageBasis,
  usageReason: current.usageReason,
  usageSampleCount: current.usageSampleCount,
  usageDefectRate: current.usageDefectRate,
  parentPerProductQty: current.parentPerProductQty,
  availableQty: current.availableQty,
  allocatedAvailableQty: current.allocatedAvailableQty,
  exactPeggedQty: current.exactPeggedQty,
  reservedQty: current.reservedQty,
  safetyStockQty: current.safetyStockQty,
  mainWarehousePublicAvailableQty: current.mainWarehousePublicAvailableQty,
  preparationAvailableQty: current.preparationAvailableQty,
  preparationAdoptedQty: current.preparationAdoptedQty,
  preparationPoolKey: current.preparationPoolKey,
  preparationSharedAvailableQty: current.preparationSharedAvailableQty,
  preparationOwnedAvailableQty: current.preparationOwnedAvailableQty,
  preparationUncoveredBeforeSharedQty:
      current.preparationUncoveredBeforeSharedQty,
  preparationAdoptableSharedQty: current.preparationAdoptableSharedQty,
  preparationSharedSupplySlices: current.preparationSharedSupplySlices,
  mainWarehouseOpenSafetySupplyQty: current.mainWarehouseOpenSafetySupplyQty,
  mainWarehouseSafetyReplenishmentGapQty:
      current.mainWarehouseSafetyReplenishmentGapQty,
  inboundQty: current.inboundQty,
  externalFutureCoverageQty: current.externalFutureCoverageQty,
  internalCommittedOutputQty: current.internalCommittedOutputQty,
  publicSurplusApprovedInboundQty: current.publicSurplusApprovedInboundQty,
  publicSurplusRemainingQty: current.publicSurplusRemainingQty,
  sharedFutureClaimedQty: current.sharedFutureClaimedQty,
  sharedFuturePendingQty: current.sharedFuturePendingQty,
  lateSharedFutureAvailableQty: current.lateSharedFutureAvailableQty,
  additionalSupplyRecommendedQty: current.additionalSupplyRecommendedQty,
  sharedFutureClaimableQty: current.sharedFutureClaimableQty,
  netShortageQty: current.netShortageQty,
  planningUncoveredQty: current.planningUncoveredQty,
  plannedOutputQty: current.plannedOutputQty,
  minOrderQty: current.minOrderQty,
  orderMultipleQty: current.orderMultipleQty,
  selectedWarehousesAvailableQty: current.selectedWarehousesAvailableQty,
  selectedOtherWarehouseTransferableQty:
      current.selectedOtherWarehouseTransferableQty,
  publicSurplusExpectedDate: current.publicSurplusExpectedDate,
  sharedFutureSupplyRefs: current.sharedFutureSupplyRefs,
  shortageQty: current.shortageQty,
  demandSupplyGapQty: current.demandSupplyGapQty,
  requirementState: current.requirementState,
  planAnchorAnalysisLineId: current.planAnchorAnalysisLineId,
  delegatedToAnalysisLineId: current.delegatedToAnalysisLineId,
  delegatedToSourceRef: current.delegatedToSourceRef,
  delegatedToRequestedQty: current.delegatedToRequestedQty,
  aggregateDelegatedQty: current.aggregateDelegatedQty,
  aggregateTargetMaterialLineId: current.aggregateTargetMaterialLineId,
  aggregatePreparation: current.aggregatePreparation,
  sourceSuggestion: current.sourceSuggestion,
  sourceConfirmed: current.sourceConfirmed,
  routeConfirmed: current.routeConfirmed,
  lowerLevelPending: current.lowerLevelPending,
  bomMissing: current.bomMissing,
  rdTaskNo: current.rdTaskNo,
  expectedReadyDate: current.expectedReadyDate,
  status: current.status,
  controlStage: current.controlStage,
  consumptionBasis: current.consumptionBasis,
  basisOutputQty: current.basisOutputQty,
  allowPartialPackage: current.allowPartialPackage,
  hardGate: current.hardGate,
  notifiedTargets: current.notifiedTargets,
  borrowedInQty: current.borrowedInQty,
  borrowedOutQty: current.borrowedOutQty,
  borrowRefs: current.borrowRefs,
  crossReallocatedInQty: current.crossReallocatedInQty,
  crossReallocatedOutQty: current.crossReallocatedOutQty,
  priorityPendingQty: current.priorityPendingQty,
  priorityMakeSupplementQty: current.priorityMakeSupplementQty,
  priorityFulfilledQty: current.priorityFulfilledQty,
  crossReallocationRefs: current.crossReallocationRefs,
  warehouseStocks: current.warehouseStocks,
  flowStage: current.flowStage,
  actionable: current.actionable,
  owningWarehouseId: owner.warehouseId,
  owningWarehouseName: owner.warehouseName,
  owningWorkshopId: owner.workshopId,
  owningWorkshopName: owner.workshopName,
);

ProductionMaterialAnalysisProduct _productWithOwnership(
  ProductionMaterialAnalysisProduct current,
  _Ownership owner,
) => ProductionMaterialAnalysisProduct(
  analysisLineId: current.analysisLineId,
  sourceType: current.sourceType,
  rootMaterialLineId: current.rootMaterialLineId,
  sourceRef: current.sourceRef,
  sourceReason: current.sourceReason,
  salesOrderItemId: current.salesOrderItemId,
  orderId: current.orderId,
  orderNo: current.orderNo,
  orderDate: current.orderDate,
  deliveryDate: current.deliveryDate,
  clientName: current.clientName,
  goodsId: current.goodsId,
  goodsCode: current.goodsCode,
  goodsName: current.goodsName,
  spec: current.spec,
  colorId: current.colorId,
  colorName: current.colorName,
  unitId: current.unitId,
  unitName: current.unitName,
  unitRate: current.unitRate,
  requestedQty: current.requestedQty,
  generatedQty: current.generatedQty,
  submittedQty: current.submittedQty,
  approvedQty: current.approvedQty,
  remainingQty: current.remainingQty,
  issuedPlanQty: current.issuedPlanQty,
  canIssueSurplus: current.canIssueSurplus,
  serverCanSchedule: current.serverCanSchedule,
  serverMaxSchedulableQty: current.serverMaxSchedulableQty,
  scheduleBlockedReason: current.scheduleBlockedReason,
  readyNowQty: current.readyNowQty,
  readyStartQty: current.readyStartQty,
  readyFinishQty: current.readyFinishQty,
  readyShipQty: current.readyShipQty,
  readyByDateQty: current.readyByDateQty,
  readinessRatio: current.readinessRatio,
  hasProductionMaterialChildren: current.hasProductionMaterialChildren,
  status: current.status,
  allocationPriority: current.allocationPriority,
  parentAnalysisLineId: current.parentAnalysisLineId,
  parentGoodsName: current.parentGoodsName,
  planExecutionStatus: current.planExecutionStatus,
  latestPlanId: current.latestPlanId,
  latestPlanNo: current.latestPlanNo,
  planExecutionPlannedQty: current.planExecutionPlannedQty,
  planExecutionInboundQty: current.planExecutionInboundQty,
  planExecutionProgressRatio: current.planExecutionProgressRatio,
  planExecutionReportedQty: current.planExecutionReportedQty,
  planExecutionZeroMaterial: current.planExecutionZeroMaterial,
  planExecutionWorkshopName: current.planExecutionWorkshopName,
  planExecutionResponsibleName: current.planExecutionResponsibleName,
  planExecutionWorkshopId: current.planExecutionWorkshopId,
  planExecutionResponsibleId: current.planExecutionResponsibleId,
  owningWarehouseId: owner.warehouseId,
  owningWarehouseName: owner.warehouseName,
  owningWorkshopId: owner.workshopId,
  owningWorkshopName: owner.workshopName,
);
