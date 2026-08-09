// Pre-plan material analysis contracts.
//
// The server is authoritative for BOM expansion, stock allocation and ready
// quantities. These models intentionally parse returned facts only; the
// Flutter client never derives availability from inventory fields.

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

  /// Same material reached through multiple BOM paths shares one action group.
  /// Route confirmation/notification is issued once for the representative.
  final String? actionGroupKey;
  final String? materialKey;
  final double requiredQty;
  final double perProductQty;
  final double availableQty;
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
    notifiedTargets: _notificationTargets(
      json['notifiedTargets'] ?? json['downstreamReferences'],
    ),
    actionable:
        _boolOrNull(json['actionable']) ?? ((_int(json['level']) ?? 0) == 1),
  );
}

class MaterialAnalysisNotificationTarget {
  const MaterialAnalysisNotificationTarget({
    required this.target,
    this.documentType,
    this.documentId,
    this.documentNo,
    this.status,
  });

  final MaterialSupplyRoute? target;
  final String? documentType;
  final String? documentId;
  final String? documentNo;
  final String? status;

  factory MaterialAnalysisNotificationTarget.fromJson(
    Map<String, dynamic> json,
  ) => MaterialAnalysisNotificationTarget(
    target: MaterialSupplyRoute.fromWire(json['target'] ?? json['route']),
    documentType: _string(json['documentType']),
    documentId: _string(json['documentId']),
    documentNo: _string(json['documentNo']),
    status: _string(json['status']),
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
  });

  final String analysisLineId;
  final double qty;
  final String? billDate;
  final String? deliveryDate;
  final String? departmentId;
  final String? workshopName;
  final String? workerId;
  final String? teamDepartmentId;

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
  };

  /// The preview endpoint validates quantities only. Per-plan scheduling
  /// fields are submitted by the final generate command after the wizard is
  /// confirmed, keeping the existing preview contract backward compatible.
  Map<String, dynamic> toQuantityJson() => {
    'analysisLineId': analysisLineId,
    'qty': qty,
  };
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
    this.packageId,
    this.segmentIds = const [],
    this.drawIds = const [],
  });

  final String planId;
  final String? planNo;
  final String? packageId;
  final List<String> segmentIds;
  final List<String> drawIds;

  factory ProductionGeneratedPlanRef.fromJson(Map<String, dynamic> json) =>
      ProductionGeneratedPlanRef(
        planId: _string(json['planId']) ?? '',
        planNo: _string(json['planNo'] ?? json['billNo']),
        packageId: _string(json['packageId']),
        segmentIds: _stringList(json['segmentIds']),
        drawIds: _stringList(json['drawIds']),
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
  return ratio > 1 ? ratio / 100 : ratio;
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
