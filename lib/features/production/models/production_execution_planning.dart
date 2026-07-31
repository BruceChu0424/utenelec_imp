/// V155 production planning preview and confirmation contracts.
///
/// These models intentionally live outside the repository so the execution
/// segment flow can replace the legacy "child plan" DTOs without introducing
/// a circular dependency.
class ProductionPlanningPreview {
  const ProductionPlanningPreview({
    required this.planId,
    required this.warehouseId,
    required this.fingerprint,
    required this.balancedKitCoverage,
    required this.executionSegmentationReady,
    this.materials = const [],
    this.targetWarehouseMaterials = const [],
    this.executionSegments = const [],
  });

  final String planId;
  final String warehouseId;
  final String fingerprint;
  final List<ProductionPlanningMaterial> materials;
  final List<ProductionTargetWarehouseMaterial> targetWarehouseMaterials;
  final bool balancedKitCoverage;
  final bool executionSegmentationReady;
  final List<ProductionExecutionSegmentPreview> executionSegments;

  factory ProductionPlanningPreview.fromJson(Map<String, dynamic> json) {
    return ProductionPlanningPreview(
      planId: json['planId'] as String,
      warehouseId: json['warehouseId'] as String,
      fingerprint: json['fingerprint'] as String,
      materials: _decodeList(
        json['materials'],
        ProductionPlanningMaterial.fromJson,
      ),
      targetWarehouseMaterials: _decodeList(
        json['targetWarehouseMaterials'],
        ProductionTargetWarehouseMaterial.fromJson,
      ),
      balancedKitCoverage: json['balancedKitCoverage'] == true,
      executionSegmentationReady: json['executionSegmentationReady'] == true,
      executionSegments: _decodeList(
        json['executionSegments'],
        ProductionExecutionSegmentPreview.fromJson,
      ),
    );
  }
}

class ProductionPlanningMaterial {
  const ProductionPlanningMaterial({
    required this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.spec,
    this.colorId,
    this.gross,
    this.onhand,
    this.openPo,
    this.net,
    this.selfMade = false,
    this.unitId,
    this.bookStock,
    this.salesReserved,
    this.safetyStock,
    this.availableNow,
    this.openPoTotal,
    this.openPoOnTime,
    this.needDate,
    this.earliestArrivalDate,
    this.purchaseNetShortage,
    this.timelyShortage,
    this.materialStatus,
    this.allocationBacked = false,
    this.planningWriteReady = false,
  });

  final String goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? spec;
  final String? colorId;
  final double? gross;
  final double? onhand;
  final double? openPo;
  final double? net;
  final bool selfMade;
  final String? unitId;
  final double? bookStock;
  final double? salesReserved;
  final double? safetyStock;
  final double? availableNow;
  final double? openPoTotal;
  final double? openPoOnTime;
  final String? needDate;
  final String? earliestArrivalDate;
  final double? purchaseNetShortage;
  final double? timelyShortage;
  final String? materialStatus;
  final bool allocationBacked;
  final bool planningWriteReady;

  factory ProductionPlanningMaterial.fromJson(Map<String, dynamic> json) {
    return ProductionPlanningMaterial(
      goodsId: json['goodsId'] as String,
      goodsCode: json['goodsCode'] as String?,
      goodsName: json['goodsName'] as String?,
      spec: json['spec'] as String?,
      colorId: json['colorId'] as String?,
      gross: _optionalDouble(json['gross']),
      onhand: _optionalDouble(json['onhand']),
      openPo: _optionalDouble(json['openPo']),
      net: _optionalDouble(json['net']),
      selfMade: json['selfMade'] == true,
      unitId: json['unitId'] as String?,
      bookStock: _optionalDouble(json['bookStock']),
      salesReserved: _optionalDouble(json['salesReserved']),
      safetyStock: _optionalDouble(json['safetyStock']),
      availableNow: _optionalDouble(json['availableNow']),
      openPoTotal: _optionalDouble(json['openPoTotal']),
      openPoOnTime: _optionalDouble(json['openPoOnTime']),
      needDate: json['needDate'] as String?,
      earliestArrivalDate: json['earliestArrivalDate'] as String?,
      purchaseNetShortage: _optionalDouble(json['purchaseNetShortage']),
      timelyShortage: _optionalDouble(json['timelyShortage']),
      materialStatus: json['materialStatus'] as String?,
      allocationBacked: json['allocationBacked'] == true,
      planningWriteReady: json['planningWriteReady'] == true,
    );
  }
}

class ProductionTargetWarehouseMaterial {
  const ProductionTargetWarehouseMaterial({
    required this.goodsId,
    required this.requiredQty,
    required this.allocatableQty,
    required this.candidateAllocatedQty,
    required this.candidateShortageQty,
    this.colorId,
  });

  final String goodsId;
  final String? colorId;
  final double requiredQty;
  final double allocatableQty;
  final double candidateAllocatedQty;
  final double candidateShortageQty;

  factory ProductionTargetWarehouseMaterial.fromJson(
    Map<String, dynamic> json,
  ) {
    return ProductionTargetWarehouseMaterial(
      goodsId: json['goodsId'] as String,
      colorId: json['colorId'] as String?,
      requiredQty: _requiredDouble(json['requiredQty']),
      allocatableQty: _requiredDouble(json['allocatableQty']),
      candidateAllocatedQty: _requiredDouble(json['candidateAllocatedQty']),
      candidateShortageQty: _requiredDouble(json['candidateShortageQty']),
    );
  }
}

class ProductionExecutionSegmentPreview {
  const ProductionExecutionSegmentPreview({
    required this.clientSegmentKey,
    required this.sourcePlanItemId,
    required this.productGoodsId,
    required this.plannedQty,
    required this.suggestedStatus,
    required this.bomFingerprint,
    this.sourceLineNo,
    this.productCode,
    this.productName,
    this.productColorId,
    this.productUnitId,
    this.workshopDepartmentId,
    this.teamDepartmentId,
    this.responsibleEmployeeId,
    this.planBeginDate,
    this.planEndDate,
    this.materials = const [],
  });

  final String clientSegmentKey;
  final String sourcePlanItemId;
  final int? sourceLineNo;
  final String productGoodsId;
  final String? productCode;
  final String? productName;
  final String? productColorId;
  final String? productUnitId;
  final double plannedQty;
  final String suggestedStatus;
  final String? workshopDepartmentId;
  final String? teamDepartmentId;
  final String? responsibleEmployeeId;
  final String? planBeginDate;
  final String? planEndDate;
  final String bomFingerprint;
  final List<ProductionExecutionMaterialPreview> materials;

  factory ProductionExecutionSegmentPreview.fromJson(
    Map<String, dynamic> json,
  ) {
    return ProductionExecutionSegmentPreview(
      clientSegmentKey: json['clientSegmentKey'] as String,
      sourcePlanItemId: json['sourcePlanItemId'] as String,
      sourceLineNo: (json['sourceLineNo'] as num?)?.toInt(),
      productGoodsId: json['productGoodsId'] as String,
      productCode: json['productCode'] as String?,
      productName: json['productName'] as String?,
      productColorId: json['productColorId'] as String?,
      productUnitId: json['productUnitId'] as String?,
      plannedQty: _requiredDouble(json['plannedQty']),
      suggestedStatus: json['suggestedStatus'] as String,
      workshopDepartmentId: json['workshopDepartmentId'] as String?,
      teamDepartmentId: json['teamDepartmentId'] as String?,
      responsibleEmployeeId: json['responsibleEmployeeId'] as String?,
      planBeginDate: json['planBeginDate'] as String?,
      planEndDate: json['planEndDate'] as String?,
      bomFingerprint: json['bomFingerprint'] as String,
      materials: _decodeList(
        json['materials'],
        ProductionExecutionMaterialPreview.fromJson,
      ),
    );
  }
}

class ProductionExecutionMaterialPreview {
  const ProductionExecutionMaterialPreview({
    required this.goodsId,
    required this.unitId,
    required this.perProductQty,
    required this.requiredQty,
    required this.availableBeforeQty,
    required this.candidateAllocatedQty,
    required this.shortageQty,
    required this.supplyRoute,
    this.colorId,
  });

  final String goodsId;
  final String? colorId;
  final String unitId;
  final double perProductQty;
  final double requiredQty;
  final double availableBeforeQty;
  final double candidateAllocatedQty;
  final double shortageQty;
  final String supplyRoute;

  factory ProductionExecutionMaterialPreview.fromJson(
    Map<String, dynamic> json,
  ) {
    return ProductionExecutionMaterialPreview(
      goodsId: json['goodsId'] as String,
      colorId: json['colorId'] as String?,
      unitId: json['unitId'] as String,
      perProductQty: _requiredDouble(json['perProductQty']),
      requiredQty: _requiredDouble(json['requiredQty']),
      availableBeforeQty: _requiredDouble(json['availableBeforeQty']),
      candidateAllocatedQty: _requiredDouble(json['candidateAllocatedQty']),
      shortageQty: _requiredDouble(json['shortageQty']),
      supplyRoute: json['supplyRoute'] as String,
    );
  }
}

class ProductionPlanningConfirmRequest {
  const ProductionPlanningConfirmRequest({
    required this.warehouseId,
    required this.idempotencyKey,
    required this.previewFingerprint,
    required this.generatePurchaseRequest,
    this.routes = const [],
    this.segments = const [],
    this.items = const [],
  });

  final String warehouseId;
  final String idempotencyKey;
  final String previewFingerprint;
  final bool generatePurchaseRequest;
  final List<ProductionMaterialRoute> routes;
  final List<ProductionExecutionSegmentConfirm> segments;

  /// Reserved compatibility field. V155 execution planning submits an empty
  /// list and uses [segments] as the authoritative scheduling input.
  final List<Map<String, dynamic>> items;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'warehouseId': warehouseId,
    'idempotencyKey': idempotencyKey,
    'previewFingerprint': previewFingerprint,
    'generatePurchaseRequest': generatePurchaseRequest,
    'routes': [for (final route in routes) route.toJson()],
    'segments': [for (final segment in segments) segment.toJson()],
    'items': [for (final item in items) Map<String, dynamic>.from(item)],
  };
}

class ProductionMaterialRoute {
  const ProductionMaterialRoute({
    required this.goodsId,
    required this.supplyRoute,
    this.colorId,
  });

  final String goodsId;
  final String? colorId;
  final String supplyRoute;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'goodsId': goodsId,
    if (colorId != null) 'colorId': colorId,
    'supplyRoute': supplyRoute,
  };
}

class ProductionExecutionSegmentConfirm {
  const ProductionExecutionSegmentConfirm({
    required this.clientSegmentKey,
    required this.sourcePlanItemId,
    required this.requestedStatus,
    required this.plannedQty,
    required this.bomFingerprint,
    this.workshopDepartmentId,
    this.teamDepartmentId,
    this.responsibleEmployeeId,
    this.planBeginDate,
    this.planEndDate,
  });

  final String clientSegmentKey;
  final String sourcePlanItemId;
  final String requestedStatus;
  final double plannedQty;
  final String? workshopDepartmentId;
  final String? teamDepartmentId;
  final String? responsibleEmployeeId;
  final String? planBeginDate;
  final String? planEndDate;
  final String bomFingerprint;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'clientSegmentKey': clientSegmentKey,
    'sourcePlanItemId': sourcePlanItemId,
    'requestedStatus': requestedStatus,
    'plannedQty': plannedQty,
    if (workshopDepartmentId != null)
      'workshopDepartmentId': workshopDepartmentId,
    if (teamDepartmentId != null) 'teamDepartmentId': teamDepartmentId,
    if (responsibleEmployeeId != null)
      'responsibleEmployeeId': responsibleEmployeeId,
    if (planBeginDate != null) 'planBeginDate': planBeginDate,
    if (planEndDate != null) 'planEndDate': planEndDate,
    'bomFingerprint': bomFingerprint,
  };
}

class ProductionPlanningConfirmResult {
  const ProductionPlanningConfirmResult({
    required this.packageId,
    required this.status,
    required this.replayed,
    this.subplans = const [],
    this.purchaseRequest,
    this.subcontractApplication,
    this.drawDocument,
    this.executionSegments = const [],
    this.drawDocuments = const [],
  });

  final String packageId;
  final String status;
  final bool replayed;
  final List<ProductionGeneratedSubplan> subplans;
  final ProductionGeneratedDocument? purchaseRequest;
  final ProductionGeneratedDocument? subcontractApplication;
  final ProductionGeneratedDocument? drawDocument;
  final List<ProductionExecutionSegmentResult> executionSegments;
  final List<ProductionGeneratedDocument> drawDocuments;

  factory ProductionPlanningConfirmResult.fromJson(Map<String, dynamic> json) {
    return ProductionPlanningConfirmResult(
      packageId: json['packageId'] as String,
      status: json['status'] as String,
      replayed: json['replayed'] == true,
      subplans: _decodeList(
        json['subplans'],
        ProductionGeneratedSubplan.fromJson,
      ),
      purchaseRequest: _decodeOptional(
        json['purchaseRequest'],
        ProductionGeneratedDocument.fromJson,
      ),
      subcontractApplication: _decodeOptional(
        json['subcontractApplication'],
        ProductionGeneratedDocument.fromJson,
      ),
      drawDocument: _decodeOptional(
        json['drawDocument'],
        ProductionGeneratedDocument.fromJson,
      ),
      executionSegments: _decodeList(
        json['executionSegments'],
        ProductionExecutionSegmentResult.fromJson,
      ),
      drawDocuments: _decodeList(
        json['drawDocuments'],
        ProductionGeneratedDocument.fromJson,
      ),
    );
  }
}

class ProductionGeneratedSubplan {
  const ProductionGeneratedSubplan({
    required this.planId,
    required this.lineCount,
    this.billNo,
    this.workshopName,
  });

  final String planId;
  final String? billNo;
  final int lineCount;
  final String? workshopName;

  factory ProductionGeneratedSubplan.fromJson(Map<String, dynamic> json) {
    return ProductionGeneratedSubplan(
      planId: json['planId'] as String,
      billNo: json['billNo'] as String?,
      lineCount: (json['lineCount'] as num).toInt(),
      workshopName: json['workshopName'] as String?,
    );
  }
}

class ProductionGeneratedDocument {
  const ProductionGeneratedDocument({
    required this.requestId,
    required this.requestBillNo,
    required this.lineCount,
    this.skippedSelfMade = const [],
  });

  final String requestId;
  final String requestBillNo;
  final int lineCount;
  final List<String> skippedSelfMade;

  factory ProductionGeneratedDocument.fromJson(Map<String, dynamic> json) {
    return ProductionGeneratedDocument(
      requestId: json['requestId'] as String,
      requestBillNo: json['requestBillNo'] as String,
      lineCount: (json['lineCount'] as num).toInt(),
      skippedSelfMade: [
        for (final value in json['skippedSelfMade'] as List? ?? const [])
          value.toString(),
      ],
    );
  }
}

class ProductionExecutionSegmentResult {
  const ProductionExecutionSegmentResult({
    required this.segmentId,
    required this.segmentCode,
    required this.clientSegmentKey,
    required this.sourcePlanItemId,
    required this.productGoodsId,
    required this.plannedQty,
    required this.status,
    this.productColorId,
    this.workshopDepartmentId,
    this.teamDepartmentId,
    this.responsibleEmployeeId,
    this.planBeginDate,
    this.planEndDate,
    this.materials = const [],
    this.drawDocument,
  });

  final String segmentId;
  final String segmentCode;
  final String clientSegmentKey;
  final String sourcePlanItemId;
  final String productGoodsId;
  final String? productColorId;
  final double plannedQty;
  final String status;
  final String? workshopDepartmentId;
  final String? teamDepartmentId;
  final String? responsibleEmployeeId;
  final String? planBeginDate;
  final String? planEndDate;
  final List<ProductionExecutionMaterialResult> materials;
  final ProductionGeneratedDocument? drawDocument;

  factory ProductionExecutionSegmentResult.fromJson(Map<String, dynamic> json) {
    return ProductionExecutionSegmentResult(
      segmentId: json['segmentId'] as String,
      segmentCode: json['segmentCode'] as String,
      clientSegmentKey: json['clientSegmentKey'] as String,
      sourcePlanItemId: json['sourcePlanItemId'] as String,
      productGoodsId: json['productGoodsId'] as String,
      productColorId: json['productColorId'] as String?,
      plannedQty: _requiredDouble(json['plannedQty']),
      status: json['status'] as String,
      workshopDepartmentId: json['workshopDepartmentId'] as String?,
      teamDepartmentId: json['teamDepartmentId'] as String?,
      responsibleEmployeeId: json['responsibleEmployeeId'] as String?,
      planBeginDate: json['planBeginDate'] as String?,
      planEndDate: json['planEndDate'] as String?,
      materials: _decodeList(
        json['materials'],
        ProductionExecutionMaterialResult.fromJson,
      ),
      drawDocument: _decodeOptional(
        json['drawDocument'],
        ProductionGeneratedDocument.fromJson,
      ),
    );
  }
}

class ProductionExecutionMaterialResult {
  const ProductionExecutionMaterialResult({
    required this.demandId,
    required this.goodsId,
    required this.unitId,
    required this.perProductQty,
    required this.requiredQty,
    required this.stockAllocatedQty,
    required this.shortageQty,
    required this.supplyRoute,
    this.colorId,
  });

  final String demandId;
  final String goodsId;
  final String? colorId;
  final String unitId;
  final double perProductQty;
  final double requiredQty;
  final double stockAllocatedQty;
  final double shortageQty;
  final String supplyRoute;

  factory ProductionExecutionMaterialResult.fromJson(
    Map<String, dynamic> json,
  ) {
    return ProductionExecutionMaterialResult(
      demandId: json['demandId'] as String,
      goodsId: json['goodsId'] as String,
      colorId: json['colorId'] as String?,
      unitId: json['unitId'] as String,
      perProductQty: _requiredDouble(json['perProductQty']),
      requiredQty: _requiredDouble(json['requiredQty']),
      stockAllocatedQty: _requiredDouble(json['stockAllocatedQty']),
      shortageQty: _requiredDouble(json['shortageQty']),
      supplyRoute: json['supplyRoute'] as String,
    );
  }
}

/// Persisted execution segment shown after the planning package is confirmed.
class ProductionExecutionSegmentView {
  const ProductionExecutionSegmentView({
    required this.id,
    required this.packageId,
    required this.planId,
    required this.sourcePlanItemId,
    required this.segmentCode,
    required this.productGoodsId,
    required this.plannedQty,
    required this.reportedQty,
    required this.remainingQty,
    required this.status,
    required this.materialKindCount,
    required this.shortageKindCount,
    required this.materialReady,
    required this.lockVersion,
    this.segmentNo,
    this.productCode,
    this.productName,
    this.productColorId,
    this.productUnitId,
    this.workshopDepartmentId,
    this.workshopName,
    this.teamDepartmentId,
    this.teamName,
    this.responsibleEmployeeId,
    this.responsibleEmployeeName,
    this.planBeginDate,
    this.planEndDate,
  });

  final String id;
  final String packageId;
  final String planId;
  final String sourcePlanItemId;
  final int? segmentNo;
  final String segmentCode;
  final String productGoodsId;
  final String? productCode;
  final String? productName;
  final String? productColorId;
  final String? productUnitId;
  final double plannedQty;
  final double reportedQty;
  final double remainingQty;
  final String status;
  final String? workshopDepartmentId;
  final String? workshopName;
  final String? teamDepartmentId;
  final String? teamName;
  final String? responsibleEmployeeId;
  final String? responsibleEmployeeName;
  final String? planBeginDate;
  final String? planEndDate;
  final int materialKindCount;
  final int shortageKindCount;
  final bool materialReady;
  final int lockVersion;

  factory ProductionExecutionSegmentView.fromJson(Map<String, dynamic> json) {
    return ProductionExecutionSegmentView(
      id: json['id'] as String,
      packageId: json['packageId'] as String,
      planId: json['planId'] as String,
      sourcePlanItemId: json['sourcePlanItemId'] as String,
      segmentNo: (json['segmentNo'] as num?)?.toInt(),
      segmentCode: json['segmentCode'] as String,
      productGoodsId: json['productGoodsId'] as String,
      productCode: json['productCode'] as String?,
      productName: json['productName'] as String?,
      productColorId: json['productColorId'] as String?,
      productUnitId: json['productUnitId'] as String?,
      plannedQty: _requiredDouble(json['plannedQty']),
      reportedQty: _requiredDouble(json['reportedQty']),
      remainingQty: _requiredDouble(json['remainingQty']),
      status: json['status'] as String,
      workshopDepartmentId: json['workshopDepartmentId'] as String?,
      workshopName: json['workshopName'] as String?,
      teamDepartmentId: json['teamDepartmentId'] as String?,
      teamName: json['teamName'] as String?,
      responsibleEmployeeId: json['responsibleEmployeeId'] as String?,
      responsibleEmployeeName: json['responsibleEmployeeName'] as String?,
      planBeginDate: json['planBeginDate'] as String?,
      planEndDate: json['planEndDate'] as String?,
      materialKindCount: (json['materialKindCount'] as num?)?.toInt() ?? 0,
      shortageKindCount: (json['shortageKindCount'] as num?)?.toInt() ?? 0,
      materialReady: json['materialReady'] == true,
      lockVersion: (json['lockVersion'] as num).toInt(),
    );
  }
}

double _requiredDouble(Object? value) => (value as num).toDouble();

double? _optionalDouble(Object? value) => (value as num?)?.toDouble();

List<T> _decodeList<T>(
  Object? value,
  T Function(Map<String, dynamic>) decoder,
) {
  return [
    for (final item in value as List? ?? const [])
      decoder(Map<String, dynamic>.from(item as Map)),
  ];
}

T? _decodeOptional<T>(Object? value, T Function(Map<String, dynamic>) decoder) {
  if (value is! Map) return null;
  return decoder(Map<String, dynamic>.from(value));
}
