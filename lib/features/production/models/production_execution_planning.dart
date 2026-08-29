/// Production planning preview and confirmation contracts.
///
/// These models intentionally live outside the repository so the execution
/// segment flow can replace the legacy "child plan" DTOs without introducing
/// a circular dependency.
/// Smaller than the minimum persisted planning quantity (0.0001).
const double kProductionPlanningQuantityEpsilon = 0.000001;

String formatProductionPlanningQuantity(double value) =>
    _formatProductionDecimal(value, 4);

String formatProductionPlanningUsage(double value) =>
    _formatProductionDecimal(value, 6);

double aggregateProductionPlanningMaterialUsage(
  Iterable<ProductionExecutionMaterialPreview> materials,
  double totalProductQty,
) {
  final entries = materials.toList(growable: false);
  if (entries.isEmpty) return 0;
  final exact = entries.any(
    (material) => material.requirementMode == 'EXACT_SNAPSHOT',
  );
  if (!exact || totalProductQty <= kProductionPlanningQuantityEpsilon) {
    return entries.first.perProductQty;
  }
  final totalRequired = entries.fold<double>(
    0,
    (sum, material) => sum + material.requiredQty,
  );
  return totalRequired / totalProductQty;
}

String formatProductionPlanningGroupedMaterialUsage(
  String requirementMode,
  double perProductQty,
) {
  final value = formatProductionPlanningUsage(perProductQty);
  return requirementMode == 'EXACT_SNAPSHOT'
      ? '按包/批(分段合计均耗) $value'
      : '单台用量 $value';
}

String? productionZeroMaterialReasonText(
  String materialRequirementMode,
  String? zeroMaterialReason,
) {
  if (materialRequirementMode != 'ZERO_MATERIAL') return null;
  return switch (zeroMaterialReason) {
    'DIRECT_MAKE' => '无需生产领料：直接自制',
    'PLAN_BOM_OVERRIDE' => '无需生产领料：本计划 BOM 例外',
    'NO_PRODUCTION_HARD_GATE' => '无需生产领料：仅发货或参考物料',
    _ => '无需生产领料：原因待核验',
  };
}

String _formatProductionDecimal(double value, int scale) {
  final fixed = value.toStringAsFixed(scale);
  final withoutTrailingZeros = fixed.replaceFirst(RegExp(r'0+$'), '');
  return withoutTrailingZeros.endsWith('.')
      ? withoutTrailingZeros.substring(0, withoutTrailingZeros.length - 1)
      : withoutTrailingZeros;
}

bool isValidProductionPlanningQuantityText(String raw) {
  final value = raw.trim();
  return RegExp(
    r'^(?:[0-9]+|[0-9]+\.[0-9]{1,4}|\.[0-9]{1,4})$',
  ).hasMatch(value);
}

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
    this.noBomPlanItemIds = const [],
  });

  final String planId;
  final String warehouseId;
  final String fingerprint;
  final List<ProductionPlanningMaterial> materials;
  final List<ProductionTargetWarehouseMaterial> targetWarehouseMaterials;
  final bool balancedKitCoverage;
  final bool executionSegmentationReady;
  final List<ProductionExecutionSegmentPreview> executionSegments;
  final List<String> noBomPlanItemIds;

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
      noBomPlanItemIds: _decodeList(
        json['noBomPlanItemIds'],
        (e) => e as String,
      ),
    );
  }
}

extension ProductionPlanningPreviewIntegrity on ProductionPlanningPreview {
  /// 「无 BOM」不再拦截排产：原材料/叶子件（含自制叶子件，原料走车间领料、本就不进 BOM）
  /// 无论作为组件还是顶层产品都合法——自制叶子件缺料由后端派生「造 N 个」裸子计划，
  /// 可直接报工入库。保留此 getter 供对话框/详细排产调用处兼容，按策略恒为 false。
  bool get hasBlockingBomGaps => false;
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
    this.sourceType,
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
  final String? sourceType;

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
      sourceType: json['sourceType'] as String?,
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
    this.productSpec,
    this.productColorId,
    this.productUnitId,
    this.workshopDepartmentId,
    this.teamDepartmentId,
    this.responsibleEmployeeId,
    this.planBeginDate,
    this.planEndDate,
    this.materialRequirementMode = 'DEMANDED',
    this.zeroMaterialReason,
    this.materials = const [],
  });

  final String clientSegmentKey;
  final String sourcePlanItemId;
  final int? sourceLineNo;
  final String productGoodsId;
  final String? productCode;
  final String? productName;
  final String? productSpec;
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
  final String materialRequirementMode;
  final String? zeroMaterialReason;
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
      productSpec: json['productSpec'] as String?,
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
      materialRequirementMode:
          json['materialRequirementMode'] as String? ?? 'DEMANDED',
      zeroMaterialReason: json['zeroMaterialReason'] as String?,
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
    this.requirementMode = 'LINEAR',
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
  final String requirementMode;

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
      requirementMode: json['requirementMode'] as String? ?? 'LINEAR',
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

  /// Reserved compatibility field. Execution planning submits an empty
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

  factory ProductionMaterialRoute.fromJson(Map<String, dynamic> json) {
    return ProductionMaterialRoute(
      goodsId: json['goodsId'] as String,
      colorId: json['colorId'] as String?,
      supplyRoute: json['supplyRoute'] as String,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'goodsId': goodsId,
    if (colorId != null) 'colorId': colorId,
    'supplyRoute': supplyRoute,
  };
}

/// Builds the explicit supply-route overrides accepted by the planning API.
///
/// MAKE shortages are expanded into child production plans by the server and
/// must not be submitted as a user-selected material route. Stock-covered
/// materials likewise need no route override.
List<ProductionMaterialRoute> buildProductionMaterialSupplyRoutes(
  Iterable<ProductionExecutionSegmentPreview> segments, {
  double shortageEpsilon = kProductionPlanningQuantityEpsilon,
}) {
  final routes = <String, ProductionMaterialRoute>{};
  for (final segment in segments) {
    for (final material in segment.materials) {
      if (material.shortageQty <= shortageEpsilon) continue;
      if (material.supplyRoute != 'BUY' &&
          material.supplyRoute != 'SUBCONTRACT') {
        continue;
      }
      final key = '${material.goodsId}|${material.colorId ?? ''}';
      routes.putIfAbsent(
        key,
        () => ProductionMaterialRoute(
          goodsId: material.goodsId,
          colorId: material.colorId,
          supplyRoute: material.supplyRoute,
        ),
      );
    }
  }
  return routes.values.toList(growable: false);
}

/// Aggregates only the direct BOM materials carried by execution segments.
///
/// [ProductionPlanningPreview.materials] may contain recursively exploded
/// lower-level components. Those components belong to a derived MAKE child
/// plan and must not be presented as documents created by the current plan.
List<ProductionPlanningMaterial> buildProductionDirectReviewMaterials(
  ProductionPlanningPreview preview,
) {
  String key(String goodsId, String? colorId) => '$goodsId|${colorId ?? ''}';

  final detailsByKey = <String, ProductionPlanningMaterial>{};
  for (final material in preview.materials) {
    detailsByKey.putIfAbsent(
      key(material.goodsId, material.colorId),
      () => material,
    );
  }

  final directByKey = <String, _DirectPlanningMaterialAggregate>{};
  for (final segment in preview.executionSegments) {
    for (final material in segment.materials) {
      final materialKey = key(material.goodsId, material.colorId);
      final aggregate = directByKey.putIfAbsent(
        materialKey,
        () => _DirectPlanningMaterialAggregate(material),
      );
      aggregate.requiredQty += material.requiredQty;
      aggregate.shortageQty += material.shortageQty;
    }
  }

  return [
    for (final entry in directByKey.entries)
      _directReviewMaterial(entry.value, detailsByKey[entry.key]),
  ];
}

ProductionPlanningMaterial _directReviewMaterial(
  _DirectPlanningMaterialAggregate aggregate,
  ProductionPlanningMaterial? details,
) {
  final direct = aggregate.material;
  final route = direct.supplyRoute;
  final sourceType = switch (route) {
    'BUY' => '采购',
    'SUBCONTRACT' => '委外',
    'MAKE' => details?.sourceType ?? '自制',
    _ => details?.sourceType,
  };
  return ProductionPlanningMaterial(
    goodsId: direct.goodsId,
    goodsCode: details?.goodsCode,
    goodsName: details?.goodsName,
    spec: details?.spec,
    colorId: direct.colorId,
    gross: aggregate.requiredQty,
    selfMade: route == 'MAKE' && (details?.selfMade ?? false),
    unitId: direct.unitId,
    bookStock: details?.bookStock ?? direct.availableBeforeQty,
    availableNow: details?.availableNow ?? direct.availableBeforeQty,
    timelyShortage: aggregate.shortageQty,
    sourceType: sourceType,
  );
}

class _DirectPlanningMaterialAggregate {
  _DirectPlanningMaterialAggregate(this.material);

  final ProductionExecutionMaterialPreview material;
  double requiredQty = 0;
  double shortageQty = 0;
}

class ProductionPlanningDraftView {
  const ProductionPlanningDraftView({
    required this.draftId,
    required this.planId,
    required this.warehouseId,
    required this.status,
    required this.previewFingerprint,
    required this.segmentCount,
    required this.generatePurchaseRequest,
    required this.plannedAt,
    required this.plannedBy,
    this.routes = const [],
    this.segments = const [],
  });

  final String draftId;
  final String planId;
  final String warehouseId;
  final String status;
  final String previewFingerprint;
  final int segmentCount;
  final bool generatePurchaseRequest;
  final String plannedAt;
  final String plannedBy;
  final List<ProductionMaterialRoute> routes;
  final List<ProductionExecutionSegmentConfirm> segments;

  factory ProductionPlanningDraftView.fromJson(Map<String, dynamic> json) {
    final rawRequest = json['request'];
    final request = rawRequest is Map
        ? Map<String, dynamic>.from(rawRequest)
        : const <String, dynamic>{};
    return ProductionPlanningDraftView(
      draftId: json['draftId'] as String,
      planId: json['planId'] as String,
      warehouseId: json['warehouseId'] as String,
      status: json['status'] as String,
      previewFingerprint: json['previewFingerprint'] as String,
      segmentCount: (json['segmentCount'] as num).toInt(),
      generatePurchaseRequest: json['generatePurchaseRequest'] == true,
      plannedAt: json['plannedAt'] as String,
      plannedBy: json['plannedBy'] as String,
      routes: _decodeList(request['routes'], ProductionMaterialRoute.fromJson),
      segments: _decodeList(
        request['segments'],
        ProductionExecutionSegmentConfirm.fromJson,
      ),
    );
  }
}

class ProductionExecutionSegmentConfirm {
  const ProductionExecutionSegmentConfirm({
    required this.clientSegmentKey,
    required this.sourcePlanItemId,
    required this.requestedStatus,
    required this.plannedQty,
    required this.bomFingerprint,
    this.deferUntilManualRelease = false,
    this.workshopDepartmentId,
    this.teamDepartmentId,
    this.responsibleEmployeeId,
    this.planBeginDate,
    this.planEndDate,
  });

  final String clientSegmentKey;
  final String sourcePlanItemId;
  final String requestedStatus;

  /// True only when the dispatcher explicitly chose to hold this WAITING
  /// segment until a later manual release. Ordinary material shortages keep
  /// this false so receipt-driven readiness may promote them automatically.
  final bool deferUntilManualRelease;
  final double plannedQty;
  final String? workshopDepartmentId;
  final String? teamDepartmentId;
  final String? responsibleEmployeeId;
  final String? planBeginDate;
  final String? planEndDate;
  final String bomFingerprint;

  factory ProductionExecutionSegmentConfirm.fromJson(
    Map<String, dynamic> json,
  ) {
    return ProductionExecutionSegmentConfirm(
      clientSegmentKey: json['clientSegmentKey'] as String,
      sourcePlanItemId: json['sourcePlanItemId'] as String,
      requestedStatus: json['requestedStatus'] as String,
      deferUntilManualRelease: json['deferUntilManualRelease'] == true,
      plannedQty: _requiredDouble(json['plannedQty']),
      workshopDepartmentId: json['workshopDepartmentId'] as String?,
      teamDepartmentId: json['teamDepartmentId'] as String?,
      responsibleEmployeeId: json['responsibleEmployeeId'] as String?,
      planBeginDate: json['planBeginDate'] as String?,
      planEndDate: json['planEndDate'] as String?,
      bomFingerprint: json['bomFingerprint'] as String,
    );
  }
  Map<String, dynamic> toJson() => <String, dynamic>{
    'clientSegmentKey': clientSegmentKey,
    'sourcePlanItemId': sourcePlanItemId,
    'requestedStatus': requestedStatus,
    'deferUntilManualRelease': deferUntilManualRelease,
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
    this.materialRequirementMode = 'DEMANDED',
    this.zeroMaterialReason,
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
  final String materialRequirementMode;
  final String? zeroMaterialReason;
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
      materialRequirementMode:
          json['materialRequirementMode'] as String? ?? 'DEMANDED',
      zeroMaterialReason: json['zeroMaterialReason'] as String?,
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
    this.requirementMode = 'LINEAR',
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
  final String requirementMode;

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
      requirementMode: json['requirementMode'] as String? ?? 'LINEAR',
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
    required this.autoPromoteWhenReady,
    required this.materialKindCount,
    required this.shortageKindCount,
    required this.materialReady,
    required this.lockVersion,
    this.materialDemandCount = 0,
    this.fullyIssuedDemandCount = 0,
    this.materialIssued = false,
    this.fqcPendingQty = 0,
    this.fqcPassedQty = 0,
    this.fqcFailedQty = 0,
    this.finishedInboundPendingQty = 0,
    this.inboundQty = 0,
    this.finishedInboundRejectedQty = 0,
    this.ordinaryRemainingQty = 0,
    this.fqcRecoveryAvailableQty = 0,
    this.fqcReworkAvailableQty = 0,
    this.fqcReplacementAvailableQty = 0,
    this.fqcReplacementReadyQty = 0,
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
  final bool autoPromoteWhenReady;
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
  final int materialDemandCount;
  final int fullyIssuedDemandCount;
  final bool materialIssued;
  final double fqcPendingQty;
  final double fqcPassedQty;
  final double fqcFailedQty;
  final double finishedInboundPendingQty;
  final double inboundQty;
  final double finishedInboundRejectedQty;
  final double ordinaryRemainingQty;
  final double fqcRecoveryAvailableQty;
  final double fqcReworkAvailableQty;
  final double fqcReplacementAvailableQty;
  final double fqcReplacementReadyQty;
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
      autoPromoteWhenReady: json['autoPromoteWhenReady'] != false,
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
      materialDemandCount: (json['materialDemandCount'] as num?)?.toInt() ?? 0,
      fullyIssuedDemandCount:
          (json['fullyIssuedDemandCount'] as num?)?.toInt() ?? 0,
      materialIssued: json['materialIssued'] == true,
      fqcPendingQty: _optionalDouble(json['fqcPendingQty']) ?? 0,
      fqcPassedQty: _optionalDouble(json['fqcPassedQty']) ?? 0,
      fqcFailedQty: _optionalDouble(json['fqcFailedQty']) ?? 0,
      finishedInboundPendingQty:
          _optionalDouble(json['finishedInboundPendingQty']) ?? 0,
      inboundQty: _optionalDouble(json['inboundQty']) ?? 0,
      finishedInboundRejectedQty:
          _optionalDouble(json['finishedInboundRejectedQty']) ?? 0,
      ordinaryRemainingQty:
          _optionalDouble(json['ordinaryRemainingQty']) ??
          _optionalDouble(json['remainingQty']) ??
          0,
      fqcRecoveryAvailableQty:
          _optionalDouble(json['fqcRecoveryAvailableQty']) ?? 0,
      fqcReworkAvailableQty:
          _optionalDouble(json['fqcReworkAvailableQty']) ?? 0,
      fqcReplacementAvailableQty:
          _optionalDouble(json['fqcReplacementAvailableQty']) ?? 0,
      fqcReplacementReadyQty:
          _optionalDouble(json['fqcReplacementReadyQty']) ?? 0,
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
