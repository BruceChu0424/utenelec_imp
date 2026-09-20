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
    this.drawRequested = false,
    this.canRequestDraw = false,
    this.canSplitBatch = false,
    this.sourceSegmentId,
    this.splitReplaced = false,
    this.hasSharedMaterialActivity = false,
    this.hasPendingReturn = false,
    bool? hasAvailableMaterial,
    this.hasMaterialActivity = false,
    this.hasUnregisteredMaterial = false,
    this.continuousSupply = false,
    this.startRoute,
    this.canConfirmRoute = false,
    this.routeChangeable = false,
    this.suggestedStartRoute,
    this.materialKindCount = 0,
    this.materialIssuedKindCount = 0,
    this.materialPartialIssuedKindCount = 0,
    this.materialAwaitingWarehouseKindCount = 0,
    this.materialDrawableKindCount = 0,
    this.materialLineSidePendingKindCount = 0,
    this.materialPreparingKindCount = 0,
    this.materialShortKindCount = 0,
    this.materialShortDirectKindCount = 0,
    this.materialSupportedOutputQty = 0,
    this.materialPreparedOutputQty = 0,
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
  }) : hasAvailableMaterial = hasAvailableMaterial ?? hasUnregisteredMaterial;

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
  final bool drawRequested;
  final bool canRequestDraw;
  final bool canSplitBatch;
  final String? sourceSegmentId;
  final bool splitReplaced;
  final bool hasSharedMaterialActivity;
  final bool hasPendingReturn;
  final bool hasAvailableMaterial;

  /// Actual issue/settlement history for this exact task, including reversals.
  final bool hasMaterialActivity;

  /// A positive issued-but-unregistered balance from the material ledger.
  /// This is independent of kit readiness and whether all material is issued.
  final bool hasUnregisteredMaterial;

  /// 按增量备料(ADR-095 起的唯一含义)：持续生产恒为真；曾按持续生产备过部分料
  /// 再改齐套的工单也保持为真。是否「持续生产」看 [startRoute]。
  final bool continuousSupply;

  /// 已确认的开工路线(V599)：FULL_KIT/BATCH/CONTINUOUS；null=待车间确认。
  final String? startRoute;

  /// 待确认生产路线(V599)：等待物料且尚未选路，「下一步」首条=确认生产路线。
  final bool canConfirmRoute;

  /// 开工前（且尚无报工）可更改路线(ADR-095)：已备料、已领料、直送已投入全部保留。
  final bool routeChangeable;

  /// 路线记忆(V602 恢复)：同产品最近一次确认的开工路线。只作未确认行的预填
  /// 展示（黄标提醒核对），选中才提交，不自动生效。
  final String? suggestedStartRoute;

  /// 逐种物料事实(ADR-095/V628)：每种正式物料需求落在且只落在一个桶里——
  /// 已领 / 缺（等采购委外到货 或 等同车间子件直送）/ 可领 / 待仓库发 /
  /// 线边仓待自动投入 / 备料中。零料任务 [materialKindCount] 为 0。
  final int materialKindCount;
  final int materialIssuedKindCount;

  /// 实领了一部分、尚未领足的种数（说明用，不与其它桶互斥）。
  final int materialPartialIssuedKindCount;
  final int materialAwaitingWarehouseKindCount;
  final int materialDrawableKindCount;
  final int materialLineSidePendingKindCount;
  final int materialPreparingKindCount;
  final int materialShortKindCount;

  /// 缺料里由同车间上下层直送供给、等子件工单完成流转的种数。
  final int materialShortDirectKindCount;

  /// 已实领物料共同支持的可产量 / 已预留物料(含未领)共同支持的可产量。
  final double materialSupportedOutputQty;
  final double materialPreparedOutputQty;

  /// 已备齐(预留足量或已领)的种数 = 总种数 - 缺料种数。
  int get materialCoveredKindCount =>
      (materialKindCount - materialShortKindCount).clamp(0, materialKindCount);

  /// 每种物料都已实领到车间(含直送已投入)。零料任务视为已领齐。
  bool get materialAllIssued =>
      materialKindCount == 0 || materialIssuedKindCount >= materialKindCount;

  /// 路线的中文短名(V599)：齐套生产 / 分批生产 / 持续生产；未确认为空。
  String get startRouteLabel => switch (startRoute) {
    'FULL_KIT' => '齐套生产',
    'BATCH' => '分批生产',
    'CONTINUOUS' => '持续生产',
    _ => '',
  };

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
    drawRequested: json['drawRequested'] == true,
    canRequestDraw: json['canRequestDraw'] == true,
    canSplitBatch: json['canSplitBatch'] == true,
    sourceSegmentId: json['sourceSegmentId'] as String?,
    splitReplaced: json['splitReplaced'] == true,
    hasSharedMaterialActivity: json['hasSharedMaterialActivity'] == true,
    hasPendingReturn: json['hasPendingReturn'] == true,
    hasAvailableMaterial: json['hasAvailableMaterial'] as bool?,
    hasMaterialActivity: json['hasMaterialActivity'] == true,
    hasUnregisteredMaterial: json['hasUnregisteredMaterial'] == true,
    continuousSupply: json['continuousSupply'] == true,
    startRoute: json['startRoute'] as String?,
    canConfirmRoute: json['canConfirmRoute'] == true,
    routeChangeable: json['routeChangeable'] == true,
    suggestedStartRoute: json['suggestedStartRoute'] as String?,
    materialKindCount: (json['materialKindCount'] as num?)?.toInt() ?? 0,
    materialIssuedKindCount:
        (json['materialIssuedKindCount'] as num?)?.toInt() ?? 0,
    materialPartialIssuedKindCount:
        (json['materialPartialIssuedKindCount'] as num?)?.toInt() ?? 0,
    materialAwaitingWarehouseKindCount:
        (json['materialAwaitingWarehouseKindCount'] as num?)?.toInt() ?? 0,
    materialDrawableKindCount:
        (json['materialDrawableKindCount'] as num?)?.toInt() ?? 0,
    materialLineSidePendingKindCount:
        (json['materialLineSidePendingKindCount'] as num?)?.toInt() ?? 0,
    materialPreparingKindCount:
        (json['materialPreparingKindCount'] as num?)?.toInt() ?? 0,
    materialShortKindCount:
        (json['materialShortKindCount'] as num?)?.toInt() ?? 0,
    materialShortDirectKindCount:
        (json['materialShortDirectKindCount'] as num?)?.toInt() ?? 0,
    materialSupportedOutputQty:
        (json['materialSupportedOutputQty'] as num?)?.toDouble() ?? 0,
    materialPreparedOutputQty:
        (json['materialPreparedOutputQty'] as num?)?.toDouble() ?? 0,
  );
}

/// 车间任务的一种物料的事实(ADR-095)：数量为基础单位；状态桶与列表汇总同口径。
class ProductionWorkshopTaskMaterial {
  const ProductionWorkshopTaskMaterial({
    required this.demandId,
    required this.goodsCode,
    required this.goodsName,
    required this.supplyRoute,
    required this.directSupply,
    required this.requiredQty,
    required this.reservedQty,
    required this.requestedUnissuedQty,
    required this.requestableQty,
    required this.lineSidePendingQty,
    required this.issuedQty,
    required this.shortageQty,
    required this.directReceivedQty,
    required this.directAvailableQty,
    required this.warehouseAvailableQty,
    required this.state,
    this.colorName,
    this.unitName,
    this.producingSegments,
  });

  final String demandId;
  final String goodsCode;
  final String goodsName;
  final String? colorName;
  final String? unitName;

  /// BUY / SUBCONTRACT / MAKE。
  final String supplyRoute;
  final bool directSupply;
  final double requiredQty;
  final double reservedQty;
  final double requestedUnissuedQty;
  final double requestableQty;
  final double lineSidePendingQty;
  final double issuedQty;
  final double shortageQty;
  final double directReceivedQty;
  final double directAvailableQty;

  /// 仓库里当前可给本需求用的实物（专属来源权益 + 允许动用的公共库存），与齐套
  /// 提升同口径；齐套生产到齐前不预留，靠它回答「到了多少」。
  final double warehouseAvailableQty;

  /// ISSUED / SHORT / SHORT_DIRECT / DRAWABLE / AWAITING_WAREHOUSE /
  /// LINE_SIDE_PENDING / PREPARING。
  final String state;

  /// 同车间承担直送责任的子件工单：`编号|状态` 以顿号分隔；非自制为空。
  final String? producingSegments;

  /// 来源口径：仓库领料(采购/委外/自制入库)还是同车间直送。
  String get sourceLabel => directSupply
      ? '同车间直送'
      : switch (supplyRoute) {
          'BUY' => '采购 · 仓库领料',
          'SUBCONTRACT' => '委外 · 仓库领料',
          'MAKE' => '自制 · 仓库领料',
          _ => '仓库领料',
        };

  String get stateLabel => switch (state) {
    'ISSUED' => '已领到车间',
    'SHORT_DIRECT' => '等同车间子件直送',
    'SHORT' => switch (supplyRoute) {
      'BUY' => '等采购到货',
      'SUBCONTRACT' => '等委外回厂',
      _ => '等待到货',
    },
    'DRAWABLE' => '已备好 · 可领料',
    'AWAITING_WAREHOUSE' => '已申请 · 待仓库发料',
    'LINE_SIDE_PENDING' => '直送料待开工投入',
    'PREPARING' => '备料中',
    _ => state,
  };

  /// 子件工单的可读摘要：`ZX0001 生产中、ZX0002 已完工`。
  String? get producingSegmentsLabel {
    final raw = producingSegments;
    if (raw == null || raw.isEmpty) return null;
    return raw
        .split('、')
        .map((entry) {
          final parts = entry.split('|');
          final status = parts.length > 1 ? parts[1] : '';
          final word = switch (status) {
            'WAITING' => '等待物料',
            'READY' || 'DISPATCHED' => '可开工',
            'IN_PROGRESS' => '生产中',
            'COMPLETED' => '已完工',
            _ => status,
          };
          return word.isEmpty ? parts.first : '${parts.first} $word';
        })
        .join('、');
  }

  factory ProductionWorkshopTaskMaterial.fromJson(
    Map<String, dynamic> json,
  ) => ProductionWorkshopTaskMaterial(
    demandId: json['demandId'] as String? ?? '',
    goodsCode: json['goodsCode'] as String? ?? '',
    goodsName: json['goodsName'] as String? ?? '',
    colorName: json['colorName'] as String?,
    unitName: json['unitName'] as String?,
    supplyRoute: json['supplyRoute'] as String? ?? '',
    directSupply: json['directSupply'] == true,
    requiredQty: (json['requiredQty'] as num?)?.toDouble() ?? 0,
    reservedQty: (json['reservedQty'] as num?)?.toDouble() ?? 0,
    requestedUnissuedQty:
        (json['requestedUnissuedQty'] as num?)?.toDouble() ?? 0,
    requestableQty: (json['requestableQty'] as num?)?.toDouble() ?? 0,
    lineSidePendingQty: (json['lineSidePendingQty'] as num?)?.toDouble() ?? 0,
    issuedQty: (json['issuedQty'] as num?)?.toDouble() ?? 0,
    shortageQty: (json['shortageQty'] as num?)?.toDouble() ?? 0,
    directReceivedQty: (json['directReceivedQty'] as num?)?.toDouble() ?? 0,
    directAvailableQty: (json['directAvailableQty'] as num?)?.toDouble() ?? 0,
    warehouseAvailableQty:
        (json['warehouseAvailableQty'] as num?)?.toDouble() ?? 0,
    state: json['state'] as String? ?? '',
    producingSegments: json['producingSegments'] as String?,
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
