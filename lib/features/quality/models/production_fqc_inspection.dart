class ProductionFqcInspection {
  const ProductionFqcInspection({
    required this.id,
    required this.sourceReportId,
    required this.sourceReportItemId,
    required this.reportedQty,
    required this.passedQty,
    required this.failedQty,
    required this.remainingQty,
    required this.authorizedInboundQty,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.reportNo,
    this.sourcePlanItemId,
    this.planId,
    this.planNo,
    this.executionSegmentId,
    this.executionSegmentSalesAllocationId,
    this.warehouseId,
    this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.colorId,
    this.colorName,
    this.unitId,
    this.unitName,
    this.unitRate = 1,
    this.reportMakerId,
    this.sheetId,
    this.sheetNo,
    this.warehouseName,
    this.place,
    this.registrationRemark,
    this.receiverName,
  });

  final String id;
  final String sourceReportId;
  final String sourceReportItemId;
  final String? reportNo;
  final String? sourcePlanItemId;
  final String? planId;
  final String? planNo;
  final String? executionSegmentId;
  final String? executionSegmentSalesAllocationId;
  final String? warehouseId;
  final String? goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? colorId;
  final String? colorName;
  final String? unitId;
  final String? unitName;
  final double unitRate;
  final double reportedQty;
  final double passedQty;
  final double failedQty;
  final double remainingQty;
  final double authorizedInboundQty;
  final String status;
  final String? reportMakerId;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// V547 所属品质检查单（历史任务可能为空 = 「无检查单」）。
  final String? sheetId;
  final String? sheetNo;

  /// 来自仓库送检登记的只读事实：成品仓、库位快照、登记备注、收货人。
  final String? warehouseName;
  final String? place;
  final String? registrationRemark;
  final String? receiverName;

  bool get active => status == 'PENDING' || status == 'PARTIAL';

  factory ProductionFqcInspection.fromJson(Map<String, dynamic> json) {
    double number(String key) => (json[key] as num?)?.toDouble() ?? 0;
    DateTime instant(String key) =>
        DateTime.tryParse(json[key]?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);
    return ProductionFqcInspection(
      id: json['id'] as String? ?? '',
      sourceReportId: json['sourceReportId'] as String? ?? '',
      sourceReportItemId: json['sourceReportItemId'] as String? ?? '',
      reportNo: json['reportNo'] as String?,
      sourcePlanItemId: json['sourcePlanItemId'] as String?,
      planId: json['planId'] as String?,
      planNo: json['planNo'] as String?,
      executionSegmentId: json['executionSegmentId'] as String?,
      executionSegmentSalesAllocationId:
          json['executionSegmentSalesAllocationId'] as String?,
      warehouseId: json['warehouseId'] as String?,
      goodsId: json['goodsId'] as String?,
      goodsCode: json['goodsCode'] as String?,
      goodsName: json['goodsName'] as String?,
      colorId: json['colorId'] as String?,
      colorName: json['colorName'] as String?,
      unitId: json['unitId'] as String?,
      unitName: json['unitName'] as String?,
      unitRate: number('unitRate'),
      reportedQty: number('reportedQty'),
      passedQty: number('passedQty'),
      failedQty: number('failedQty'),
      remainingQty: number('remainingQty'),
      authorizedInboundQty: number('authorizedInboundQty'),
      status: json['status'] as String? ?? 'PENDING',
      reportMakerId: json['reportMakerId'] as String?,
      createdAt: instant('createdAt'),
      updatedAt: instant('updatedAt'),
      sheetId: json['sheetId'] as String?,
      sheetNo: json['sheetNo'] as String?,
      warehouseName: json['warehouseName'] as String?,
      place: json['place'] as String?,
      registrationRemark: json['registrationRemark'] as String?,
      receiverName: json['receiverName'] as String?,
    );
  }
}

/// V547 品质检查单头：待检处置队列一行一张；数量守恒仍在逐条 inspection。
class ProductionFqcInspectionSheet {
  const ProductionFqcInspectionSheet({
    required this.id,
    required this.sheetNo,
    this.warehouseId,
    this.warehouseName,
    this.receiverEmployeeId,
    this.receiverName,
    this.remark,
    this.sourceKind,
    required this.itemCount,
    required this.activeCount,
    this.pendingQtyText,
    this.reportNos,
    this.goodsSummary,
    required this.status,
    required this.createdAt,
  });

  final String id;
  final String sheetNo;
  final String? warehouseId;
  final String? warehouseName;
  final String? receiverEmployeeId;
  final String? receiverName;
  final String? remark;
  final String? sourceKind;
  final int itemCount;
  final int activeCount;

  /// 按单位分组的待检数量文本（服务端拼好，不跨单位相加），如 `20 只 · 3 箱`。
  final String? pendingQtyText;
  final String? reportNos;
  final String? goodsSummary;
  final String status;
  final DateTime createdAt;

  bool get active => status == 'ACTIVE';

  factory ProductionFqcInspectionSheet.fromJson(Map<String, dynamic> json) =>
      ProductionFqcInspectionSheet(
        id: json['id'] as String? ?? '',
        sheetNo: json['sheetNo'] as String? ?? '',
        warehouseId: json['warehouseId'] as String?,
        warehouseName: json['warehouseName'] as String?,
        receiverEmployeeId: json['receiverEmployeeId'] as String?,
        receiverName: json['receiverName'] as String?,
        remark: json['remark'] as String?,
        sourceKind: json['sourceKind'] as String?,
        itemCount: (json['itemCount'] as num?)?.toInt() ?? 0,
        activeCount: (json['activeCount'] as num?)?.toInt() ?? 0,
        pendingQtyText: json['pendingQtyText'] as String?,
        reportNos: json['reportNos'] as String?,
        goodsSummary: json['goodsSummary'] as String?,
        status: json['status'] as String? ?? 'ACTIVE',
        createdAt:
            DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
}

/// 检查单办理视图：头 + 逐条 inspection。
class ProductionFqcInspectionSheetDetail {
  const ProductionFqcInspectionSheetDetail({
    required this.sheet,
    required this.inspections,
  });

  final ProductionFqcInspectionSheet sheet;
  final List<ProductionFqcInspection> inspections;

  List<ProductionFqcInspection> get activeInspections =>
      inspections.where((item) => item.active).toList(growable: false);

  factory ProductionFqcInspectionSheetDetail.fromJson(
    Map<String, dynamic> json,
  ) => ProductionFqcInspectionSheetDetail(
    sheet: ProductionFqcInspectionSheet.fromJson(
      json['sheet'] as Map<String, dynamic>? ?? const {},
    ),
    inspections:
        (json['inspections'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(ProductionFqcInspection.fromJson)
            .toList(growable: false) ??
        const [],
  );
}

class ProductionFqcDecisionResult {
  const ProductionFqcDecisionResult({
    required this.decisionEventId,
    required this.inspection,
    required this.replay,
  });

  final String decisionEventId;
  final ProductionFqcInspection inspection;
  final bool replay;

  factory ProductionFqcDecisionResult.fromJson(Map<String, dynamic> json) =>
      ProductionFqcDecisionResult(
        decisionEventId: json['decisionEventId'] as String? ?? '',
        inspection: ProductionFqcInspection.fromJson(
          json['inspection'] as Map<String, dynamic>? ?? const {},
        ),
        replay: json['replay'] as bool? ?? false,
      );
}
