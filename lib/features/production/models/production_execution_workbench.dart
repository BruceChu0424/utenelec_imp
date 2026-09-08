class ProductionExecutionWorkbenchGroup {
  const ProductionExecutionWorkbenchGroup({
    required this.rootType,
    required this.rootId,
    required this.rootLabel,
    required this.status,
    required this.salesOrderCount,
    required this.salesOrderHasMore,
    required this.workOrderCount,
    required this.workOrderHasMore,
    required this.workshopCount,
    required this.workshopHasMore,
    required this.productCount,
    required this.productHasMore,
    required this.mixedUnits,
    required this.executionUnitCount,
    required this.executionUnitHasMore,
    required this.planCount,
    required this.segmentCount,
    required this.waitingCount,
    required this.readyCount,
    required this.dispatchedCount,
    required this.inProgressCount,
    required this.completedCount,
    required this.materialReadyCount,
    required this.warehouseReadyCount,
    required this.issuedCount,
    required this.reportableCount,
    required this.fqcPendingCount,
    required this.finishedInboundPendingCount,
    required this.mine,
    this.salesOrderPreview,
    this.workOrderPreview,
    this.workshopPreview,
    this.productCodePreview,
    this.productNamePreview,
    this.productColorPreview,
    this.quantitySummary,
    this.earliestBeginDate,
    this.latestEndDate,
    this.ownerEmployeeName,
    this.analyzedAt,
    this.rootProgressRatio,
  });

  final String rootType;
  final String rootId;
  final String rootLabel;
  final String status;
  final String? salesOrderPreview;
  final int salesOrderCount;
  final bool salesOrderHasMore;
  final String? workOrderPreview;
  final int workOrderCount;
  final bool workOrderHasMore;
  final String? workshopPreview;
  final int workshopCount;
  final bool workshopHasMore;
  final String? productCodePreview;
  final String? productNamePreview;
  final String? productColorPreview;
  final int productCount;
  final bool productHasMore;
  final String? quantitySummary;
  final bool mixedUnits;
  final int executionUnitCount;
  final bool executionUnitHasMore;
  final int planCount;
  final int segmentCount;
  final int waitingCount;
  final int readyCount;
  final int dispatchedCount;
  final int inProgressCount;
  final int completedCount;
  final int materialReadyCount;
  final int warehouseReadyCount;
  final int issuedCount;
  final int reportableCount;
  final int fqcPendingCount;
  final int finishedInboundPendingCount;
  final bool mine;
  final String? earliestBeginDate;
  final String? latestEndDate;
  final String? ownerEmployeeName;
  final String? analyzedAt;
  final double? rootProgressRatio;

  String get id => '$rootType:$rootId';

  /// 顶层产品完工进度百分比（0-100，无段时为 null，不伪装 0%）。
  int? get rootProgressPercent {
    final ratio = rootProgressRatio;
    if (ratio == null || !ratio.isFinite) return null;
    final clamped = ratio.clamp(0.0, 1.0).toDouble();
    if (clamped >= 1) return 100;
    return (clamped * 100).round().clamp(0, 99);
  }

  String get statusLabel => switch (status) {
    'ANALYZING' => '分析处理中',
    'PLAN_PENDING' => '计划待审核/下达',
    'PARTIALLY_SCHEDULED' => '部分已排 · 仍有待排数量',
    'PREPARING' => '物料不齐套 · 备料中',
    'KIT_SHORT' => '物料不齐套 · 备料中',
    'KIT_READY_PREPARING' => '物料齐套 · 备料中',
    'PREPARED' => '备料完毕',
    'IN_PROGRESS' => '生产中',
    'ASSIGNMENT_REQUIRED' => '车间信息待补录',
    _ => '状态待确认',
  };

  factory ProductionExecutionWorkbenchGroup.fromJson(
    Map<String, dynamic> json,
  ) => ProductionExecutionWorkbenchGroup(
    rootType: json['rootType'] as String? ?? 'PLAN',
    rootId: json['rootId'] as String? ?? '',
    rootLabel: json['rootLabel'] as String? ?? '生产任务',
    status: json['status'] as String? ?? '',
    salesOrderPreview: json['salesOrderPreview'] as String?,
    salesOrderCount: (json['salesOrderCount'] as num?)?.toInt() ?? 0,
    salesOrderHasMore: json['salesOrderHasMore'] == true,
    workOrderPreview: json['workOrderPreview'] as String?,
    workOrderCount: (json['workOrderCount'] as num?)?.toInt() ?? 0,
    workOrderHasMore: json['workOrderHasMore'] == true,
    workshopPreview: json['workshopPreview'] as String?,
    workshopCount: (json['workshopCount'] as num?)?.toInt() ?? 0,
    workshopHasMore: json['workshopHasMore'] == true,
    productCodePreview: json['productCodePreview'] as String?,
    productNamePreview: json['productNamePreview'] as String?,
    productColorPreview: json['productColorPreview'] as String?,
    productCount: (json['productCount'] as num?)?.toInt() ?? 0,
    productHasMore: json['productHasMore'] == true,
    quantitySummary: json['quantitySummary'] as String?,
    mixedUnits: json['mixedUnits'] == true,
    executionUnitCount: (json['executionUnitCount'] as num?)?.toInt() ?? 0,
    executionUnitHasMore: json['executionUnitHasMore'] == true,
    planCount: (json['planCount'] as num?)?.toInt() ?? 0,
    segmentCount: (json['segmentCount'] as num?)?.toInt() ?? 0,
    waitingCount: (json['waitingCount'] as num?)?.toInt() ?? 0,
    readyCount: (json['readyCount'] as num?)?.toInt() ?? 0,
    dispatchedCount: (json['dispatchedCount'] as num?)?.toInt() ?? 0,
    inProgressCount: (json['inProgressCount'] as num?)?.toInt() ?? 0,
    completedCount: (json['completedCount'] as num?)?.toInt() ?? 0,
    materialReadyCount: (json['materialReadyCount'] as num?)?.toInt() ?? 0,
    warehouseReadyCount: (json['warehouseReadyCount'] as num?)?.toInt() ?? 0,
    issuedCount: (json['issuedCount'] as num?)?.toInt() ?? 0,
    reportableCount: (json['reportableCount'] as num?)?.toInt() ?? 0,
    fqcPendingCount: (json['fqcPendingCount'] as num?)?.toInt() ?? 0,
    finishedInboundPendingCount:
        (json['finishedInboundPendingCount'] as num?)?.toInt() ?? 0,
    mine: json['mine'] == true,
    earliestBeginDate: json['earliestBeginDate'] as String?,
    latestEndDate: json['latestEndDate'] as String?,
    ownerEmployeeName: json['ownerEmployeeName'] as String?,
    analyzedAt: json['analyzedAt'] as String?,
    rootProgressRatio: (json['rootProgressRatio'] as num?)?.toDouble(),
  );
}

class ProductionExecutionWorkbenchSegment {
  const ProductionExecutionWorkbenchSegment({
    required this.segmentId,
    required this.planId,
    required this.planNo,
    required this.segmentCode,
    required this.plannedQty,
    required this.reportedQty,
    required this.remainingReportQty,
    required this.fqcPendingQty,
    required this.fqcPassedQty,
    required this.fqcFailedQty,
    required this.finishedInboundPendingQty,
    required this.inboundQty,
    required this.segmentStatus,
    required this.materialStatus,
    required this.preparationStatus,
    required this.materialReady,
    required this.warehouseReady,
    required this.issued,
    required this.canDispatch,
    required this.canStart,
    required this.canReport,
    required this.canBatchReport,
    required this.lockVersion,
    required this.zeroMaterial,
    this.canRecheckMaterial = false,
    this.salesOrderNos,
    this.workshopDepartmentId,
    this.workshopName,
    this.responsibleEmployeeName,
    this.productCode,
    this.productName,
    this.productColorName,
    this.productUnitName,
    this.blockedReason,
    this.planBeginDate,
    this.planEndDate,
  });

  final String segmentId;
  final String planId;
  final String planNo;
  final String segmentCode;
  final String? salesOrderNos;
  final String? workshopDepartmentId;
  final String? workshopName;
  final String? responsibleEmployeeName;
  final String? productCode;
  final String? productName;
  final String? productColorName;
  final String? productUnitName;
  final double plannedQty;
  final double reportedQty;
  final double remainingReportQty;
  final double fqcPendingQty;
  final double fqcPassedQty;
  final double fqcFailedQty;
  final double finishedInboundPendingQty;
  final double inboundQty;
  final String segmentStatus;
  final String materialStatus;
  final String preparationStatus;
  final bool materialReady;
  final bool warehouseReady;
  final bool issued;
  final bool canDispatch;
  final bool canStart;
  final bool canReport;
  final bool canBatchReport;
  final String? blockedReason;
  final String? planBeginDate;
  final String? planEndDate;
  final int lockVersion;
  final bool zeroMaterial;
  final bool canRecheckMaterial;

  /// 报工进度比（报工量 / 计划量，0-1；计划量为 0 时为 null）。
  double? get reportProgressRatio {
    if (plannedQty <= 0) return null;
    return reportedQty.clamp(0, plannedQty) / plannedQty;
  }

  String get materialStatusLabel => switch (materialStatus) {
    'KIT_READY' =>
      preparationStatus == 'PREPARED' ? '物料齐套 · 备料完毕' : '物料齐套 · 备料中',
    'KIT_SHORT' => '物料不齐套 · 备料中',
    _ => '物料状态待确认',
  };

  String get executionStatusLabel => switch (segmentStatus) {
    'WAITING' => '待料',
    'READY' => '工单已确认',
    'DISPATCHED' => '历史工单已确认',
    'IN_PROGRESS' => '生产中',
    'COMPLETED' => '已完成',
    'CANCELLED' => '已取消',
    'REVERSED' => '已反向',
    _ => '执行状态待确认',
  };

  factory ProductionExecutionWorkbenchSegment.fromJson(
    Map<String, dynamic> json,
  ) => ProductionExecutionWorkbenchSegment(
    segmentId: json['segmentId'] as String? ?? '',
    planId: json['planId'] as String? ?? '',
    planNo: json['planNo'] as String? ?? '—',
    segmentCode: json['segmentCode'] as String? ?? '—',
    salesOrderNos: json['salesOrderNos'] as String?,
    workshopDepartmentId: json['workshopDepartmentId'] as String?,
    workshopName: json['workshopName'] as String?,
    responsibleEmployeeName: json['responsibleEmployeeName'] as String?,
    productCode: json['productCode'] as String?,
    productName: json['productName'] as String?,
    productColorName: json['productColorName'] as String?,
    productUnitName: json['productUnitName'] as String?,
    plannedQty: (json['plannedQty'] as num?)?.toDouble() ?? 0,
    reportedQty: (json['reportedQty'] as num?)?.toDouble() ?? 0,
    remainingReportQty: (json['remainingReportQty'] as num?)?.toDouble() ?? 0,
    fqcPendingQty: (json['fqcPendingQty'] as num?)?.toDouble() ?? 0,
    fqcPassedQty: (json['fqcPassedQty'] as num?)?.toDouble() ?? 0,
    fqcFailedQty: (json['fqcFailedQty'] as num?)?.toDouble() ?? 0,
    finishedInboundPendingQty:
        (json['finishedInboundPendingQty'] as num?)?.toDouble() ?? 0,
    inboundQty: (json['inboundQty'] as num?)?.toDouble() ?? 0,
    segmentStatus: json['segmentStatus'] as String? ?? '',
    materialStatus: json['materialStatus'] as String? ?? '',
    preparationStatus: json['preparationStatus'] as String? ?? '',
    materialReady: json['materialReady'] == true,
    warehouseReady: json['warehouseReady'] == true,
    issued: json['issued'] == true,
    canDispatch: json['canDispatch'] == true,
    canStart: json['canStart'] == true,
    canReport:
        json['segmentStatus'] == 'IN_PROGRESS' && json['canReport'] == true,
    canBatchReport:
        json['segmentStatus'] == 'IN_PROGRESS' &&
        json['canBatchReport'] == true,
    blockedReason: json['blockedReason'] as String?,
    planBeginDate: json['planBeginDate'] as String?,
    planEndDate: json['planEndDate'] as String?,
    lockVersion: (json['lockVersion'] as num?)?.toInt() ?? 0,
    zeroMaterial: json['zeroMaterial'] == true,
    canRecheckMaterial: json['canRecheckMaterial'] == true,
  );
}

// 2026-09-05「进行中」滑窗详情下线后客户端不再消费 workOrders()/group()；
// 2026-09-06 计划详情页重新消费 related-documents 渲染「本批次关联单据」
// （采购/委外申请与订货单、本批次计划树），单据可点进对应模块看进度。

/// 与某分析批次结构化关联的单据（服务端已按各模块数据范围过滤）。
class ProductionExecutionWorkbenchRelatedDocument {
  const ProductionExecutionWorkbenchRelatedDocument({
    required this.route,
    required this.documentType,
    required this.documentId,
    required this.documentNo,
    required this.canOpen,
    this.status,
  });

  final String route;
  final String documentType;
  final String documentId;
  final String documentNo;
  final String? status;
  final bool canOpen;

  String get statusLabel =>
      switch (status) {
        '0' => '待审核',
        '1' => '已审核',
        '-1' => '已红冲',
        _ => null,
      } ??
      '—';

  String get typeLabel => switch (documentType) {
    'PURCHASE_REQUEST' => '采购申请',
    'PURCHASE_ORDER' => '采购订单',
    'SUBCONTRACT_APPLICATION' => '委外申请',
    'SUBCONTRACT_ORDER' => '委外订单',
    'PRODUCTION_PLAN' => '生产计划',
    _ => documentType,
  };

  factory ProductionExecutionWorkbenchRelatedDocument.fromJson(
    Map<String, dynamic> json,
  ) => ProductionExecutionWorkbenchRelatedDocument(
    route: json['route'] as String? ?? '',
    documentType: json['documentType'] as String? ?? '',
    documentId: json['documentId'] as String? ?? '',
    documentNo: json['documentNo'] as String? ?? '—',
    status: json['status'] as String?,
    canOpen: json['canOpen'] == true,
  );
}
