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
    );
  }
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
