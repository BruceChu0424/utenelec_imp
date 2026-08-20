// Pre-plan material analysis contracts.
//
// The server is authoritative for BOM expansion, stock allocation and ready
// quantities. These models intentionally parse returned facts only; the
// Flutter client never derives availability from inventory fields.

import '../../../shared/models/progress_ratio.dart';

enum MaterialSupplyRoute {
  make('MAKE', '自制'),
  buy('BUY', '采购'),
  subcontract('SUBCONTRACT', '委外');

  const MaterialSupplyRoute(this.wireName, this.label);

  final String wireName;
  final String label;

  static MaterialSupplyRoute? fromWire(Object? value) {
    final text = value?.toString().trim().toUpperCase();
    for (final route in values) {
      if (route.wireName == text) return route;
    }
    return null;
  }
}

class MaterialAnalysisSourceInput {
  const MaterialAnalysisSourceInput({
    this.salesOrderItemId,
    this.sourceType,
    this.sourceRef,
    this.goodsId,
    this.colorId,
    this.unitId,
    required this.requestedQty,
    this.sourceReason,
    this.deliveryDate,
    this.initialProductNo,
  });

  final String? salesOrderItemId;
  final String? sourceType;
  final String? sourceRef;
  final String? goodsId;
  final String? colorId;
  final String? unitId;
  final double requestedQty;
  final String? sourceReason;
  final String? deliveryDate;

  /// Route-local seed for the subsequent production-plan wizard. It is not a
  /// material-analysis source field and therefore is intentionally omitted
  /// from [toJson].
  final String? initialProductNo;

  bool get isSalesSource => salesOrderItemId?.isNotEmpty == true;
  String get canonicalKey =>
      salesOrderItemId ??
      '${sourceType ?? 'MANUAL'}|${sourceRef ?? ''}|${goodsId ?? ''}|${colorId ?? ''}|${unitId ?? ''}';

  Map<String, dynamic> toJson() => {
    if (salesOrderItemId != null) 'salesOrderItemId': salesOrderItemId,
    if (sourceType != null) 'sourceType': sourceType,
    if (sourceRef != null) 'sourceRef': sourceRef,
    if (goodsId != null) 'goodsId': goodsId,
    if (colorId != null) 'colorId': colorId,
    if (unitId != null) 'unitId': unitId,
    'requestedQty': requestedQty,
    if (sourceReason != null) 'sourceReason': sourceReason,
    if (deliveryDate != null) 'deliveryDate': deliveryDate,
  };
}

/// Route state passed from the scheduling board to the independent analysis
/// page. [analysisId]/[analysisVersion] are optional so an existing analysis
/// can be refreshed using the same preview endpoint.
class ProductionMaterialAnalysisSeed {
  const ProductionMaterialAnalysisSeed({
    this.analysisId,
    this.analysisVersion,
    this.warehouseId,
    this.billDate,
    this.deliveryDate,
    this.departmentId,
    this.workshopName,
    this.workerId,
    this.sources = const [],
  });

  final String? analysisId;
  final int? analysisVersion;
  final String? warehouseId;
  final String? billDate;
  final String? deliveryDate;
  final String? departmentId;
  final String? workshopName;
  final String? workerId;
  final List<MaterialAnalysisSourceInput> sources;

  /// Resolves the route-local product number seed back to the analysis product
  /// created from the same source. Sales lines use their immutable item UUID;
  /// manual demand uses the same composite source identity as the backend.
  String? initialProductNoFor(ProductionMaterialAnalysisProduct product) {
    for (final source in sources) {
      final productNo = _trimmedOrNull(source.initialProductNo);
      if (productNo == null) continue;

      final productSalesItemId = _trimmedOrNull(product.salesOrderItemId);
      final sourceSalesItemId = _trimmedOrNull(source.salesOrderItemId);
      if (productSalesItemId != null) {
        if (_sameSourcePart(
          sourceSalesItemId,
          productSalesItemId,
          foldCase: true,
        )) {
          return productNo;
        }
        continue;
      }
      if (sourceSalesItemId != null) continue;

      if (_sameSourcePart(
            source.sourceType,
            product.sourceType,
            foldCase: true,
          ) &&
          _sameSourcePart(
            source.sourceRef,
            product.sourceRef,
            foldCase: true,
          ) &&
          _sameSourcePart(source.goodsId, product.goodsId, foldCase: true) &&
          _sameSourcePart(source.colorId, product.colorId, foldCase: true) &&
          _sameSourcePart(source.unitId, product.unitId, foldCase: true)) {
        return productNo;
      }
    }
    return null;
  }
}

class MaterialAnalysisSalesCandidatePage {
  const MaterialAnalysisSalesCandidatePage({
    required this.items,
    required this.page,
    required this.size,
    required this.total,
    required this.totalPages,
  });

  final List<MaterialAnalysisSalesCandidate> items;
  final int page;
  final int size;
  final int total;
  final int totalPages;

  List<MaterialAnalysisSalesCandidateLine> get lines => [
    for (final order in items)
      for (final line in order.lines) line.withOrder(order),
  ];

  factory MaterialAnalysisSalesCandidatePage.fromJson(
    Map<String, dynamic> json,
  ) => MaterialAnalysisSalesCandidatePage(
    items: _mapList(json['items'], MaterialAnalysisSalesCandidate.fromJson),
    page: _int(json['page']) ?? 1,
    size: _int(json['size']) ?? 20,
    total: _int(json['totalElements'] ?? json['total']) ?? 0,
    totalPages: _int(json['totalPages']) ?? 0,
  );
}

/// Object-scoped material-analysis task/history row.
///
/// Quantities are persisted server projections. The client only formats them
/// and never recomputes readiness from warehouse data.
class MaterialAnalysisListItem {
  const MaterialAnalysisListItem({
    required this.analysisId,
    required this.status,
    required this.version,
    this.fingerprint,
    this.warehouseId,
    this.warehouseCode,
    this.warehouseName,
    this.analyzedAt,
    this.updatedAt,
    this.makerId,
    this.makerName,
    this.sourceCount = 0,
    this.sourceTypes = const [],
    this.sourceRefs = const [],
    this.productLabels = const [],
    this.requestedQty = 0,
    this.submittedQty = 0,
    this.approvedQty = 0,
    this.remainingQty = 0,
    this.readyNowQty = 0,
    this.readyByDateQty = 0,
  });

  final String analysisId;
  final String status;
  final int version;
  final String? fingerprint;
  final String? warehouseId;
  final String? warehouseCode;
  final String? warehouseName;
  final String? analyzedAt;
  final String? updatedAt;
  final String? makerId;
  final String? makerName;
  final int sourceCount;
  final List<String> sourceTypes;
  final List<String> sourceRefs;
  final List<String> productLabels;
  final double requestedQty;
  final double submittedQty;
  final double approvedQty;
  final double remainingQty;
  final double readyNowQty;
  final double readyByDateQty;

  factory MaterialAnalysisListItem.fromJson(Map<String, dynamic> json) =>
      MaterialAnalysisListItem(
        analysisId: _string(json['analysisId'] ?? json['id']) ?? '',
        status: _string(json['status']) ?? 'UNKNOWN',
        version: _int(json['version']) ?? 0,
        fingerprint: _string(json['fingerprint']),
        warehouseId: _string(json['warehouseId']),
        warehouseCode: _string(json['warehouseCode']),
        warehouseName: _string(json['warehouseName']),
        analyzedAt: _string(json['analyzedAt']),
        updatedAt: _string(json['updatedAt'] ?? json['analyzedAt']),
        makerId: _string(json['makerId']),
        makerName: _string(json['makerName']),
        sourceCount: _int(json['sourceCount']) ?? 0,
        sourceTypes: _stringList(json['sourceTypes']),
        sourceRefs: _stringList(json['sourceRefs']),
        productLabels: _stringList(json['productLabels']),
        requestedQty: _double(json['requestedQty']) ?? 0,
        submittedQty: _double(json['submittedQty']) ?? 0,
        approvedQty: _double(json['approvedQty']) ?? 0,
        remainingQty: _double(json['remainingQty']) ?? 0,
        readyNowQty: _double(json['readyNowQty']) ?? 0,
        readyByDateQty: _double(json['readyByDateQty']) ?? 0,
      );
}

class MaterialAnalysisSalesCandidate {
  const MaterialAnalysisSalesCandidate({
    required this.orderId,
    this.orderNo,
    this.orderDate,
    this.deliveryDate,
    this.clientName,
    this.lines = const [],
  });

  final String orderId;
  final String? orderNo;
  final String? orderDate;
  final String? deliveryDate;
  final String? clientName;
  final List<MaterialAnalysisSalesCandidateLine> lines;

  factory MaterialAnalysisSalesCandidate.fromJson(Map<String, dynamic> json) =>
      MaterialAnalysisSalesCandidate(
        orderId: _string(json['orderId'] ?? json['id']) ?? '',
        orderNo: _string(json['orderNo'] ?? json['billNo']),
        orderDate: _string(json['orderDate'] ?? json['billDate']),
        deliveryDate: _string(json['deliveryDate'] ?? json['deliverDate']),
        clientName: _string(json['clientName']),
        lines: _mapList(
          json['lines'],
          MaterialAnalysisSalesCandidateLine.fromJson,
        ),
      );
}

class MaterialAnalysisSalesCandidateLine {
  const MaterialAnalysisSalesCandidateLine({
    required this.salesOrderItemId,
    this.lineNo,
    this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.spec,
    this.colorId,
    this.colorName,
    this.unitId,
    this.unitName,
    this.unitRate,
    this.orderedQty,
    this.alreadyPlannedQty,
    this.remainingQty,
    this.deliveryDate,
    this.analysisId,
    this.analysisStatus,
    this.analysisVersion,
    this.orderId,
    this.orderNo,
    this.orderDate,
    this.clientName,
  });

  final String salesOrderItemId;
  final int? lineNo;
  final String? goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? spec;
  final String? colorId;
  final String? colorName;
  final String? unitId;
  final String? unitName;
  final double? unitRate;
  final double? orderedQty;
  final double? alreadyPlannedQty;
  final double? remainingQty;
  final String? deliveryDate;
  final String? analysisId;
  final String? analysisStatus;
  final int? analysisVersion;
  final String? orderId;
  final String? orderNo;
  final String? orderDate;
  final String? clientName;

  factory MaterialAnalysisSalesCandidateLine.fromJson(
    Map<String, dynamic> json,
  ) => MaterialAnalysisSalesCandidateLine(
    salesOrderItemId:
        _string(json['salesOrderItemId'] ?? json['orderItemId']) ?? '',
    lineNo: _int(json['lineNo']),
    goodsId: _string(json['goodsId']),
    goodsCode: _string(json['goodsCode']),
    goodsName: _string(json['goodsName']),
    spec: _string(json['spec']),
    colorId: _string(json['colorId']),
    colorName: _string(json['colorName']),
    unitId: _string(json['unitId']),
    unitName: _string(json['unitName']),
    unitRate: _double(json['unitRate']),
    orderedQty: _double(json['orderedQty'] ?? json['qty']),
    alreadyPlannedQty: _double(json['alreadyPlannedQty'] ?? json['plannedQty']),
    remainingQty: _double(json['remainingQty'] ?? json['needQty']),
    deliveryDate: _string(json['deliveryDate'] ?? json['deliverDate']),
    analysisId: _string(json['analysisId']),
    analysisStatus: _string(json['analysisStatus']),
    analysisVersion: _int(json['analysisVersion']),
  );

  MaterialAnalysisSalesCandidateLine withOrder(
    MaterialAnalysisSalesCandidate order,
  ) => MaterialAnalysisSalesCandidateLine(
    salesOrderItemId: salesOrderItemId,
    lineNo: lineNo,
    goodsId: goodsId,
    goodsCode: goodsCode,
    goodsName: goodsName,
    spec: spec,
    colorId: colorId,
    colorName: colorName,
    unitId: unitId,
    unitName: unitName,
    orderedQty: orderedQty,
    alreadyPlannedQty: alreadyPlannedQty,
    remainingQty: remainingQty,
    deliveryDate: deliveryDate ?? order.deliveryDate,
    analysisId: analysisId,
    analysisStatus: analysisStatus,
    analysisVersion: analysisVersion,
    orderId: order.orderId,
    orderNo: order.orderNo,
    orderDate: order.orderDate,
    clientName: order.clientName,
  );
}

class ProductionMaterialAnalysisView {
  const ProductionMaterialAnalysisView({
    required this.analysisId,
    required this.version,
    required this.fingerprint,
    this.status,
    this.warehouseId,
    this.analyzedAt,
    this.products = const [],
    this.materials = const [],
    this.warehouses = const [],
    this.allowedActions = const {},
  });

  final String analysisId;
  final String? status;
  final int version;
  final String fingerprint;
  final String? warehouseId;
  final String? analyzedAt;
  final List<ProductionMaterialAnalysisProduct> products;
  final List<ProductionMaterialAnalysisMaterial> materials;
  final List<ProductionMaterialAnalysisWarehouse> warehouses;
  final Set<String> allowedActions;

  bool get routesConfirmed => materials
      .where((item) => item.shortageQty > 0)
      .every((item) => item.routeConfirmed && item.confirmedRoute != null);

  factory ProductionMaterialAnalysisView.fromJson(Map<String, dynamic> json) =>
      ProductionMaterialAnalysisView(
        analysisId: _string(json['analysisId'] ?? json['id']) ?? '',
        status: _string(json['status']),
        version: _int(json['version']) ?? 0,
        fingerprint: _string(json['fingerprint']) ?? '',
        warehouseId: _string(json['warehouseId']),
        analyzedAt: _string(
          json['analyzedAt'] ?? json['calculatedAt'] ?? json['updatedAt'],
        ),
        products: _mapList(
          json['products'],
          ProductionMaterialAnalysisProduct.fromJson,
        ),
        materials: _mapList(
          json['flatMaterials'] ?? json['materials'],
          ProductionMaterialAnalysisMaterial.fromJson,
        ),
        warehouses: _mapList(
          json['warehouses'],
          ProductionMaterialAnalysisWarehouse.fromJson,
        ),
        allowedActions: _stringList(json['allowedActions']).toSet(),
      );
}

class ProductionMaterialAnalysisProduct {
  const ProductionMaterialAnalysisProduct({
    required this.analysisLineId,
    this.sourceType,
    this.sourceRef,
    this.sourceReason,
    this.salesOrderItemId,
    this.orderId,
    this.orderNo,
    this.orderDate,
    this.deliveryDate,
    this.clientName,
    this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.spec,
    this.colorId,
    this.colorName,
    this.unitId,
    this.unitName,
    this.unitRate,
    this.requestedQty = 0,
    this.generatedQty = 0,
    this.submittedQty = 0,
    this.approvedQty = 0,
    this.remainingQty = 0,
    this.readyNowQty = 0,
    this.readyStartQty,
    this.readyFinishQty,
    this.readyShipQty,
    this.readyByDateQty,
    this.readinessRatio = 0,
    this.status,
    this.productionBomPolicy,
    this.missingBom = false,
    this.bomOverrideRequired = false,
    this.hasActiveBom,
    this.allocationPriority,
    this.parentAnalysisLineId,
    this.parentGoodsName,
    this.planExecutionStatus,
    this.latestPlanId,
    this.latestPlanNo,
  });

  final String analysisLineId;
  final String? sourceType;
  final String? sourceRef;
  final String? sourceReason;
  final String? salesOrderItemId;
  final String? orderId;
  final String? orderNo;
  final String? orderDate;
  final String? deliveryDate;
  final String? clientName;
  final String? goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? spec;
  final String? colorId;
  final String? colorName;
  final String? unitId;
  final String? unitName;
  final double? unitRate;
  final double requestedQty;
  final double generatedQty;
  final double submittedQty;
  final double approvedQty;
  final double remainingQty;
  final double readyNowQty;
  final double? readyStartQty;
  final double? readyFinishQty;
  final double? readyShipQty;
  final double? readyByDateQty;
  final double readinessRatio;
  final String? status;
  final String? productionBomPolicy;
  final bool missingBom;
  final bool bomOverrideRequired;
  final bool? hasActiveBom;
  final int? allocationPriority;

  /// For MAKE_COMPONENT self-make items: the parent assembly product this
  /// sub-component feeds into. Null for top-level sales/manual sources.
  final String? parentAnalysisLineId;
  final String? parentGoodsName;
  final String? planExecutionStatus;
  final String? latestPlanId;
  final String? latestPlanNo;

  bool get hasBomPolicyError =>
      productionBomPolicy == 'BOM_REQUIRED' &&
      (missingBom || hasActiveBom == false || bomOverrideRequired);

  factory ProductionMaterialAnalysisProduct.fromJson(
    Map<String, dynamic> json,
  ) => ProductionMaterialAnalysisProduct(
    analysisLineId: _string(json['analysisLineId'] ?? json['id']) ?? '',
    sourceType: _string(json['sourceType']),
    sourceRef: _string(json['sourceRef']),
    sourceReason: _string(json['sourceReason']),
    salesOrderItemId: _string(json['salesOrderItemId']),
    orderId: _string(json['salesOrderId'] ?? json['orderId']),
    orderNo: _string(
      json['salesOrderNo'] ?? json['orderNo'] ?? json['orderBillNo'],
    ),
    orderDate: _string(json['orderDate']),
    deliveryDate: _string(json['deliveryDate']),
    clientName: _string(json['clientName']),
    goodsId: _string(json['goodsId']),
    goodsCode: _string(json['goodsCode']),
    goodsName: _string(json['goodsName']),
    spec: _string(json['spec']),
    colorId: _string(json['colorId']),
    colorName: _string(json['colorName']),
    unitId: _string(json['unitId']),
    unitName: _string(json['unitName']),
    unitRate: _double(json['unitRate']),
    requestedQty: _double(json['requestedQty']) ?? 0,
    generatedQty: _double(json['generatedQty'] ?? json['approvedQty']) ?? 0,
    submittedQty: _double(json['submittedQty']) ?? 0,
    approvedQty: _double(json['approvedQty']) ?? 0,
    remainingQty: _double(json['remainingQty']) ?? 0,
    readyNowQty: _double(json['readyNowQty']) ?? 0,
    readyStartQty: _double(json['readyStartQty']),
    readyFinishQty: _double(json['readyFinishQty']),
    readyShipQty: _double(json['readyShipQty']),
    readyByDateQty: _double(json['readyByDateQty']),
    readinessRatio: _normaliseRatio(json['readinessRatio']),
    status: _string(json['status']),
    productionBomPolicy: _string(json['productionBomPolicy']),
    missingBom: json['missingBom'] == true,
    bomOverrideRequired: json['bomOverrideRequired'] == true,
    hasActiveBom: _boolOrNull(json['hasActiveBom']),
    allocationPriority: _int(json['allocationPriority']),
    parentAnalysisLineId: _string(json['parentAnalysisLineId']),
    parentGoodsName: _string(json['parentGoodsName']),
    planExecutionStatus: _string(json['planExecutionStatus']),
    latestPlanId: _string(json['latestPlanId']),
    latestPlanNo: _string(json['latestPlanNo']),
  );
}

class MaterialAllocationPriorityInput {
  const MaterialAllocationPriorityInput({
    required this.analysisLineId,
    required this.priority,
  });

  final String analysisLineId;
  final int priority;

  Map<String, dynamic> toJson() => {
    'analysisLineId': analysisLineId,
    'priority': priority,
  };
}

class ProductionMaterialAnalysisMaterial {
  const ProductionMaterialAnalysisMaterial({
    required this.materialLineId,
    this.analysisLineId,
    this.nodeKey,
    this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.spec,
    this.colorId,
    this.colorName,
    this.unitId,
    this.unitName,
    this.level = 0,
    this.path = const [],
    this.parentGoodsId,
    this.parentNodeKey,
    this.parentLabel,
    this.actionGroupKey,
    this.materialKey,
    this.requiredQty = 0,
    this.perProductQty = 0,
    this.availableQty = 0,
    this.allocatedAvailableQty = 0,
    this.reservedQty = 0,
    this.safetyStockQty = 0,
    this.inboundQty = 0,
    this.shortageQty = 0,
    this.sourceSuggestion,
    this.sourceConfirmed,
    this.routeConfirmed = false,
    this.routeReason,
    this.lowerLevelPending = false,
    this.expectedReadyDate,
    this.status,
    this.controlStage,
    this.consumptionBasis,
    this.basisOutputQty,
    this.allowPartialPackage,
    this.hardGate,
    this.productionBomPolicy,
    this.hasActiveBom,
    this.notifiedTargets = const [],
    this.borrowedInQty = 0,
    this.borrowedOutQty = 0,
    this.borrowRefs = const [],
    this.warehouseStocks = const [],
    required this.actionable,
  });

  final String materialLineId;
  final String? analysisLineId;
  final String? nodeKey;
  final String? goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? spec;
  final String? colorId;
  final String? colorName;
  final String? unitId;
  final String? unitName;
  final int level;
  final List<String> path;
  final String? parentGoodsId;
  final String? parentNodeKey;
  final String? parentLabel;

  /// Stable server-side identity of this BOM node's business action.
  final String? actionGroupKey;
  final String? materialKey;
  final double requiredQty;
  final double perProductQty;

  /// Qualified stock in the selected warehouse before this analysis allocates
  /// the shared pool to individual demand nodes.
  final double availableQty;

  /// The part of [availableQty] actually assigned to this demand node.
  final double allocatedAvailableQty;
  final double reservedQty;
  final double safetyStockQty;
  final double inboundQty;
  final double shortageQty;
  final MaterialSupplyRoute? sourceSuggestion;
  final MaterialSupplyRoute? sourceConfirmed;
  final bool routeConfirmed;
  final String? routeReason;
  final bool lowerLevelPending;
  final String? expectedReadyDate;
  final String? status;
  final String? controlStage;
  final String? consumptionBasis;
  final double? basisOutputQty;
  final bool? allowPartialPackage;
  final bool? hardGate;
  final String? productionBomPolicy;
  final bool? hasActiveBom;
  final List<MaterialAnalysisNotificationTarget> notifiedTargets;

  /// 现货层借用（调货）投影：本节点被其它产品借入/借出的生效数量，
  /// 以及逐笔明细（对方产品、申请量、原因）。服务端权威，客户端只展示。
  final double borrowedInQty;
  final double borrowedOutQty;
  final List<MaterialBorrowRef> borrowRefs;

  /// 分仓现货明细（服务端 v_stock_available 投影）：现货列需要解释
  /// 「在库有量但被安全库存/预留抵扣」时取这里的原始在库量。
  final List<MaterialWarehouseStock> warehouseStocks;
  final bool actionable;

  MaterialSupplyRoute? get confirmedRoute =>
      routeConfirmed ? sourceConfirmed : null;

  bool get hasBomPolicyError =>
      productionBomPolicy == 'BOM_REQUIRED' && hasActiveBom == false;

  factory ProductionMaterialAnalysisMaterial.fromJson(
    Map<String, dynamic> json,
  ) => ProductionMaterialAnalysisMaterial(
    materialLineId: _string(json['materialLineId'] ?? json['id']) ?? '',
    analysisLineId: _string(json['analysisLineId']),
    nodeKey: _string(json['nodeKey']),
    goodsId: _string(json['goodsId']),
    goodsCode: _string(json['goodsCode']),
    goodsName: _string(json['goodsName']),
    spec: _string(json['spec']),
    colorId: _string(json['colorId']),
    colorName: _string(json['colorName']),
    unitId: _string(json['unitId']),
    unitName: _string(json['unitName']),
    level: _int(json['level']) ?? 0,
    path: _path(json['path']),
    parentGoodsId: _string(json['parentGoodsId']),
    parentNodeKey: _string(json['parentNodeKey']),
    parentLabel: _string(json['parentLabel']),
    actionGroupKey: _string(json['actionGroupKey']),
    materialKey: _string(json['materialKey']),
    perProductQty: _double(json['perProductQty']) ?? 0,
    requiredQty: _double(json['requiredQty']) ?? 0,
    availableQty: _double(json['availableQty']) ?? 0,
    allocatedAvailableQty: _double(json['allocatedAvailableQty']) ?? 0,
    reservedQty: _double(json['reservedQty']) ?? 0,
    safetyStockQty: _double(json['safetyStockQty']) ?? 0,
    inboundQty: _double(json['inboundQty']) ?? 0,
    shortageQty: _double(json['shortageQty']) ?? 0,
    sourceSuggestion: MaterialSupplyRoute.fromWire(
      json['sourceSuggestion'] ?? json['suggestedRoute'],
    ),
    sourceConfirmed: MaterialSupplyRoute.fromWire(
      json['sourceConfirmed'] ?? json['selectedRoute'],
    ),
    routeConfirmed: json['routeConfirmed'] == true,
    routeReason: _string(json['routeReason']),
    lowerLevelPending: json['lowerLevelPending'] == true,
    expectedReadyDate: _string(json['expectedReadyDate']),
    status: _string(json['status'] ?? json['materialStatus']),
    controlStage: _string(json['controlStage']),
    consumptionBasis: _string(json['consumptionBasis']),
    basisOutputQty: _double(json['basisOutputQty']),
    allowPartialPackage: _boolOrNull(json['allowPartialPackage']),
    hardGate: _boolOrNull(json['hardGate']),
    productionBomPolicy: _string(
      json['productionBomPolicy'] ?? json['bomPolicy'],
    ),
    hasActiveBom: _boolOrNull(json['hasActiveBom'] ?? json['bomReady']),
    // 优先取下游引用（含单据号/状态/分摊量），它是「已下达多少、进行到哪步」
    // 的权威投影；旧版 notifiedTargets 只有路线名，仅作回退。
    notifiedTargets: _notificationTargets(
      json['downstreamReferences'] ?? json['notifiedTargets'],
    ),
    borrowedInQty: _double(json['borrowedInQty']) ?? 0,
    borrowedOutQty: _double(json['borrowedOutQty']) ?? 0,
    borrowRefs: _mapList(json['borrowRefs'], MaterialBorrowRef.fromJson),
    warehouseStocks: _mapList(
      json['warehouseBreakdown'],
      MaterialWarehouseStock.fromJson,
    ),
    actionable:
        _boolOrNull(json['actionable']) ?? ((_int(json['level']) ?? 0) == 1),
  );
}

/// 物料在某仓的现货投影：在库量 / 预留量 / 扣安全库存后可用量。
class MaterialWarehouseStock {
  const MaterialWarehouseStock({
    required this.warehouseId,
    this.warehouseCode,
    this.warehouseName,
    this.onHandQty = 0,
    this.reservedQty = 0,
    this.availableQty = 0,
  });

  final String warehouseId;
  final String? warehouseCode;
  final String? warehouseName;
  final double onHandQty;
  final double reservedQty;
  final double availableQty;

  /// 安全库存抵扣前的现货量（在库 - 预留），用于解释「有在库但现货为 0」。
  double get preSafetyQty =>
      (onHandQty - reservedQty).clamp(0.0, double.infinity);

  factory MaterialWarehouseStock.fromJson(Map<String, dynamic> json) =>
      MaterialWarehouseStock(
        warehouseId: _string(json['warehouseId'] ?? json['id']) ?? '',
        warehouseCode: _string(json['warehouseCode'] ?? json['code']),
        warehouseName: _string(json['warehouseName'] ?? json['name']),
        onHandQty: _double(json['onHandQty']) ?? 0,
        reservedQty: _double(json['reservedQty']) ?? 0,
        availableQty: _double(json['availableQty']) ?? 0,
      );
}

/// 一笔有效借用的双向投影：本节点是借出方（OUT）还是借入方（IN）、
/// 生效数量、申请数量、对方产品标签与操作原因。
class MaterialBorrowRef {
  const MaterialBorrowRef({
    required this.borrowId,
    required this.direction,
    required this.qty,
    required this.requestedQty,
    this.counterpartProduct,
    this.reason,
  });

  final String borrowId;

  /// 'IN' = 本节点借入；'OUT' = 本节点被借出。
  final String direction;
  final double qty;
  final double requestedQty;
  final String? counterpartProduct;
  final String? reason;

  bool get isInbound => direction == 'IN';

  factory MaterialBorrowRef.fromJson(Map<String, dynamic> json) =>
      MaterialBorrowRef(
        borrowId: _string(json['borrowId']) ?? '',
        direction: _string(json['direction']) ?? '',
        qty: _double(json['qty']) ?? 0,
        requestedQty: _double(json['requestedQty']) ?? 0,
        counterpartProduct: _string(json['counterpartProduct']),
        reason: _string(json['reason']),
      );
}

class MaterialAnalysisNotificationTarget {
  const MaterialAnalysisNotificationTarget({
    required this.target,
    this.documentType,
    this.documentId,
    this.documentNo,
    this.status,
    this.allocatedQty,
  });

  final MaterialSupplyRoute? target;
  final String? documentType;
  final String? documentId;
  final String? documentNo;
  final String? status;

  /// 该下游任务分摊到本物料行的数量（downstreamReferences 投影携带）。
  /// 用于估算「已提交在途量」，服务端仍以实时缺口−在途复核为准。
  final double? allocatedQty;

  factory MaterialAnalysisNotificationTarget.fromJson(
    Map<String, dynamic> json,
  ) => MaterialAnalysisNotificationTarget(
    target: MaterialSupplyRoute.fromWire(json['target'] ?? json['route']),
    documentType: _string(json['documentType']),
    documentId: _string(json['documentId']),
    documentNo: _string(json['documentNo']),
    status: _string(json['status']),
    allocatedQty: _double(json['allocatedQty']),
  );
}

class ProductionMaterialAnalysisWarehouse {
  const ProductionMaterialAnalysisWarehouse({
    required this.warehouseId,
    this.warehouseName,
  });

  final String warehouseId;
  final String? warehouseName;

  factory ProductionMaterialAnalysisWarehouse.fromJson(
    Map<String, dynamic> json,
  ) => ProductionMaterialAnalysisWarehouse(
    warehouseId: _string(json['warehouseId'] ?? json['id']) ?? '',
    warehouseName: _string(json['warehouseName'] ?? json['name']),
  );
}

/// 物料供给全链路进度（只读投影）：从「提交需求」到「入库齐套」的逐步状态。
/// 服务端沿 行动→申请→订货→审批→预计到货→收货→质检→库存 链回溯；
/// 前端只展示，不在本地推算任何一步。
class MaterialSupplyProgress {
  const MaterialSupplyProgress({
    required this.materialLineId,
    required this.route,
    required this.steps,
    this.goodsCode,
    this.goodsName,
  });

  final String materialLineId;
  final String? goodsCode;
  final String? goodsName;

  /// BUY / SUBCONTRACT / MAKE；无下游任务时为 null（步骤全为待开始）。
  final String? route;
  final List<MaterialSupplyProgressStep> steps;

  factory MaterialSupplyProgress.fromJson(Map<String, dynamic> json) =>
      MaterialSupplyProgress(
        materialLineId: _string(json['materialLineId']) ?? '',
        goodsCode: _string(json['goodsCode']),
        goodsName: _string(json['goodsName']),
        route: _string(json['route']),
        steps: _mapList(json['steps'], MaterialSupplyProgressStep.fromJson),
      );
}

class MaterialSupplyProgressStep {
  const MaterialSupplyProgressStep({
    required this.key,
    required this.label,
    required this.state,
    this.detail,
    this.docNo,
    this.at,
    this.operatorName,
  });

  final String key;
  final String label;

  /// DONE（已完成）/ CURRENT（进行中）/ WAITING（未开始）/ REJECTED（被驳回）。
  final String state;

  /// 该步骤的补充说明（数量、待办人等），无则为 null。
  final String? detail;
  final String? docNo;
  final String? at;

  /// 该步骤责任人姓名（提交人/采购人/审批人/收货人/下达人），无则 null。
  final String? operatorName;

  bool get isDone => state == 'DONE';
  bool get isCurrent => state == 'CURRENT';
  bool get isRejected => state == 'REJECTED';

  factory MaterialSupplyProgressStep.fromJson(Map<String, dynamic> json) =>
      MaterialSupplyProgressStep(
        key: _string(json['key']) ?? '',
        label: _string(json['label']) ?? '',
        state: (_string(json['state']) ?? 'WAITING').toUpperCase(),
        detail: _string(json['detail']),
        docNo: _string(json['docNo']),
        at: _string(json['at']),
        operatorName: _string(json['operatorName']),
      );
}

class MaterialRouteDecision {
  const MaterialRouteDecision({
    this.actionGroupKey,
    this.materialLineId,
    required this.route,
    this.reason,
  }) : assert(actionGroupKey != null || materialLineId != null);

  final String? actionGroupKey;
  final String? materialLineId;
  final MaterialSupplyRoute route;
  final String? reason;

  Map<String, dynamic> toJson() => {
    if (actionGroupKey != null) 'actionGroupKey': actionGroupKey,
    if (materialLineId != null) 'materialLineId': materialLineId,
    'route': route.wireName,
    if (reason != null && reason!.trim().isNotEmpty) 'reason': reason!.trim(),
  };
}

class MaterialBomOverride {
  const MaterialBomOverride({
    required this.analysisLineId,
    required this.reason,
  });

  final String analysisLineId;
  final String reason;

  Map<String, dynamic> toJson() => {
    'analysisLineId': analysisLineId,
    'reason': reason.trim(),
  };
}

/// 提交采购/委外/自制时的指定数量：二选一标识操作组，
/// 服务端按「缺口 − 在途任务」实时余量复核，超出会被拒。
class MaterialSupplyQuantityInput {
  const MaterialSupplyQuantityInput({
    this.actionGroupKey,
    this.materialLineId,
    required this.qty,
  }) : assert(actionGroupKey != null || materialLineId != null);

  final String? actionGroupKey;
  final String? materialLineId;
  final double qty;

  Map<String, dynamic> toJson() => {
    if (actionGroupKey != null) 'actionGroupKey': actionGroupKey,
    if (materialLineId != null) 'materialLineId': materialLineId,
    'qty': qty,
  };
}

class MaterialAnalysisPlanItemInput {
  const MaterialAnalysisPlanItemInput({
    required this.analysisLineId,
    required this.qty,
    this.billDate,
    this.deliveryDate,
    this.departmentId,
    this.workshopName,
    this.workerId,
    this.teamDepartmentId,
    this.productNo,
  });

  final String analysisLineId;
  final double qty;
  final String? billDate;
  final String? deliveryDate;
  final String? departmentId;
  final String? workshopName;
  final String? workerId;
  final String? teamDepartmentId;
  final String? productNo;

  Map<String, dynamic> toJson() => {
    'analysisLineId': analysisLineId,
    'qty': qty,
    if (billDate != null) 'billDate': billDate,
    if (deliveryDate != null) 'deliveryDate': deliveryDate,
    if (departmentId != null) 'departmentId': departmentId,
    if (workshopName?.trim().isNotEmpty == true)
      'workshopName': workshopName!.trim(),
    if (workerId != null) 'workerId': workerId,
    if (teamDepartmentId != null) 'teamDepartmentId': teamDepartmentId,
    if (productNo?.trim().isNotEmpty == true) 'productNo': productNo!.trim(),
  };

  /// The preview endpoint validates quantities and binds an optional explicit
  /// product number into its fingerprint. Per-plan scheduling fields remain a
  /// final-generate concern.
  Map<String, dynamic> toQuantityJson() => {
    'analysisLineId': analysisLineId,
    'qty': qty,
    if (productNo?.trim().isNotEmpty == true) 'productNo': productNo!.trim(),
  };
}

String? _trimmedOrNull(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

bool _sameSourcePart(String? left, String? right, {bool foldCase = false}) {
  final normalizedLeft = _trimmedOrNull(left);
  final normalizedRight = _trimmedOrNull(right);
  if (normalizedLeft == null || normalizedRight == null) {
    return normalizedLeft == normalizedRight;
  }
  return foldCase
      ? normalizedLeft.toLowerCase() == normalizedRight.toLowerCase()
      : normalizedLeft == normalizedRight;
}

class ProductionMaterialPlanPreview {
  const ProductionMaterialPlanPreview({
    required this.analysisId,
    required this.version,
    required this.previewFingerprint,
    required this.analysisFingerprint,
    this.warehouseId,
    this.calculatedAt,
    this.allReady = false,
    this.items = const [],
    this.plans = const [],
    this.allowedActions = const {},
  });

  final String analysisId;
  final int version;
  final String previewFingerprint;
  final String analysisFingerprint;
  final String? warehouseId;
  final String? calculatedAt;
  final bool allReady;
  final List<ProductionMaterialPlanPreviewItem> items;
  final List<ProductionMaterialPlanPreviewPlan> plans;
  final Set<String> allowedActions;

  bool get canGenerate =>
      allReady && items.isNotEmpty && items.every((item) => item.canGenerate);

  factory ProductionMaterialPlanPreview.fromJson(
    Map<String, dynamic> json,
  ) => ProductionMaterialPlanPreview(
    analysisId: _string(json['analysisId']) ?? '',
    version: _int(json['version']) ?? 0,
    previewFingerprint:
        _string(json['previewFingerprint'] ?? json['fingerprint']) ?? '',
    analysisFingerprint: _string(json['fingerprint']) ?? '',
    warehouseId: _string(json['warehouseId']),
    calculatedAt: _string(json['calculatedAt']),
    allReady: json['allReady'] == true,
    items: _mapList(json['items'], ProductionMaterialPlanPreviewItem.fromJson),
    plans: _mapList(json['plans'], ProductionMaterialPlanPreviewPlan.fromJson),
    allowedActions: _stringList(json['allowedActions']).toSet(),
  );
}

class ProductionMaterialPlanPreviewItem {
  const ProductionMaterialPlanPreviewItem({
    required this.analysisLineId,
    this.requestedQty = 0,
    this.readyNowQty = 0,
    this.selectedQty = 0,
    this.canGenerate = false,
    this.reason,
  });

  final String analysisLineId;
  final double requestedQty;
  final double readyNowQty;
  final double selectedQty;
  final bool canGenerate;
  final String? reason;

  factory ProductionMaterialPlanPreviewItem.fromJson(
    Map<String, dynamic> json,
  ) => ProductionMaterialPlanPreviewItem(
    analysisLineId: _string(json['analysisLineId']) ?? '',
    requestedQty: _double(json['requestedQty']) ?? 0,
    readyNowQty: _double(json['readyNowQty']) ?? 0,
    selectedQty: _double(json['selectedQty']) ?? 0,
    canGenerate: json['canGenerate'] == true,
    reason: _string(json['reason']),
  );
}

class ProductionMaterialPlanPreviewPlan {
  const ProductionMaterialPlanPreviewPlan({
    this.clientPlanKey,
    this.productGoodsId,
    this.qty = 0,
    this.readyNowQty = 0,
    this.segmentStatus,
  });

  final String? clientPlanKey;
  final String? productGoodsId;
  final double qty;
  final double readyNowQty;
  final String? segmentStatus;

  factory ProductionMaterialPlanPreviewPlan.fromJson(
    Map<String, dynamic> json,
  ) => ProductionMaterialPlanPreviewPlan(
    clientPlanKey: _string(json['clientPlanKey']),
    productGoodsId: _string(json['productGoodsId']),
    qty: _double(json['qty']) ?? 0,
    readyNowQty: _double(json['readyNowQty']) ?? 0,
    segmentStatus: _string(json['segmentStatus']),
  );
}

class ProductionMaterialGenerateResult {
  const ProductionMaterialGenerateResult({
    required this.analysis,
    this.plans = const [],
  });

  final ProductionMaterialAnalysisView analysis;
  final List<ProductionGeneratedPlanRef> plans;

  factory ProductionMaterialGenerateResult.fromJson(
    Map<String, dynamic> json,
  ) => ProductionMaterialGenerateResult(
    analysis: ProductionMaterialAnalysisView.fromJson(
      (json['analysis'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    plans: _mapList(json['plans'], ProductionGeneratedPlanRef.fromJson),
  );
}

class ProductionGeneratedPlanRef {
  const ProductionGeneratedPlanRef({
    required this.planId,
    this.planNo,
    this.status,
    this.packageId,
    this.segmentIds = const [],
    this.drawIds = const [],
    this.drawDocuments = const [],
  });

  final String planId;
  final String? planNo;

  /// 计划状态：DRAFT（待审核）/ APPROVED（已审核下达）。
  final String? status;
  final String? packageId;
  final List<String> segmentIds;
  final List<String> drawIds;

  /// 随计划包自动生成的物料提货单（领料单）可读列表；待审核计划为空。
  final List<ProductionGeneratedDrawRef> drawDocuments;

  factory ProductionGeneratedPlanRef.fromJson(Map<String, dynamic> json) =>
      ProductionGeneratedPlanRef(
        planId: _string(json['planId']) ?? '',
        planNo: _string(json['planNo'] ?? json['billNo']),
        status: _string(json['status']),
        packageId: _string(json['packageId']),
        segmentIds: _stringList(json['segmentIds']),
        drawIds: _stringList(json['drawIds']),
        drawDocuments: _mapList(
          json['drawDocuments'],
          ProductionGeneratedDrawRef.fromJson,
        ),
      );
}

class ProductionGeneratedDrawRef {
  const ProductionGeneratedDrawRef({required this.drawId, this.billNo});

  final String drawId;
  final String? billNo;

  factory ProductionGeneratedDrawRef.fromJson(Map<String, dynamic> json) =>
      ProductionGeneratedDrawRef(
        drawId: _string(json['drawId'] ?? json['id']) ?? '',
        billNo: _string(json['billNo'] ?? json['requestBillNo']),
      );
}

List<T> _mapList<T>(Object? raw, T Function(Map<String, dynamic>) mapper) =>
    (raw as List?)
        ?.whereType<Map<Object?, Object?>>()
        .map((value) => mapper(value.cast<String, dynamic>()))
        .toList(growable: false) ??
    const [];

List<MaterialAnalysisNotificationTarget> _notificationTargets(Object? raw) {
  final values = raw as List?;
  if (values == null) return const [];
  final result = <MaterialAnalysisNotificationTarget>[];
  for (final value in values) {
    if (value is Map<Object?, Object?>) {
      result.add(
        MaterialAnalysisNotificationTarget.fromJson(
          value.cast<String, dynamic>(),
        ),
      );
      continue;
    }
    final route = MaterialSupplyRoute.fromWire(value);
    if (route != null) {
      result.add(MaterialAnalysisNotificationTarget(target: route));
    }
  }
  return result;
}

String? _string(Object? value) {
  if (value == null) return null;
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

double? _double(Object? value) => switch (value) {
  final num number => number.toDouble(),
  final String text => double.tryParse(text),
  _ => null,
};

int? _int(Object? value) => switch (value) {
  final num number => number.toInt(),
  final String text => int.tryParse(text),
  _ => null,
};

bool? _boolOrNull(Object? value) => switch (value) {
  final bool flag => flag,
  final num number => number != 0,
  final String text when text.toLowerCase() == 'true' => true,
  final String text when text.toLowerCase() == 'false' => false,
  _ => null,
};

double _normaliseRatio(Object? value) {
  final ratio = _double(value) ?? 0;
  return normalizeProgressRatio(ratio);
}

List<String> _path(Object? value) {
  if (value is List) return value.map((item) => item.toString()).toList();
  final text = _string(value);
  if (text == null) return const [];
  return text
      .split(RegExp(r'\s*(?:>|/|→)\s*'))
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
}

List<String> _stringList(Object? value) =>
    (value as List?)?.map((item) => item.toString()).toList(growable: false) ??
    const [];
