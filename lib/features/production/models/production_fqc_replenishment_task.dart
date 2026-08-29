class ProductionFqcReplenishmentTask {
  const ProductionFqcReplenishmentTask({
    required this.taskId,
    required this.authorizationId,
    required this.dispositionCode,
    required this.quantity,
    required this.warehouseId,
    required this.goodsId,
    required this.sourceInspectionId,
    required this.sourceReportItemId,
    this.goodsCode,
    this.goodsName,
    this.colorId,
    this.unitId,
    this.sourceReportNo,
    this.materialAnalysisId,
    this.materialAnalysisItemId,
  });

  final String taskId;
  final String authorizationId;
  final String dispositionCode;
  final double quantity;
  final String warehouseId;
  final String goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? colorId;
  final String? unitId;
  final String sourceInspectionId;
  final String sourceReportItemId;
  final String? sourceReportNo;
  final String? materialAnalysisId;
  final String? materialAnalysisItemId;

  bool get analysisCreated => materialAnalysisId?.isNotEmpty == true;

  String get dispositionLabel => switch (dispositionCode) {
    'SCRAP' => '报废补产',
    'REJECT' => '拒收补产',
    _ => '品质补产',
  };

  factory ProductionFqcReplenishmentTask.fromJson(Map<String, dynamic> json) =>
      ProductionFqcReplenishmentTask(
        taskId: json['taskId'] as String? ?? '',
        authorizationId: json['authorizationId'] as String? ?? '',
        dispositionCode: json['dispositionCode'] as String? ?? '',
        quantity: (json['quantity'] as num?)?.toDouble() ?? 0,
        warehouseId: json['warehouseId'] as String? ?? '',
        goodsId: json['goodsId'] as String? ?? '',
        goodsCode: json['goodsCode'] as String?,
        goodsName: json['goodsName'] as String?,
        colorId: json['colorId'] as String?,
        unitId: json['unitId'] as String?,
        sourceInspectionId: json['sourceInspectionId'] as String? ?? '',
        sourceReportItemId: json['sourceReportItemId'] as String? ?? '',
        sourceReportNo: json['sourceReportNo'] as String?,
        materialAnalysisId: json['materialAnalysisId'] as String?,
        materialAnalysisItemId: json['materialAnalysisItemId'] as String?,
      );
}

class ProductionFqcReplenishmentMaterialTask {
  const ProductionFqcReplenishmentMaterialTask({
    required this.taskId,
    required this.authorizationId,
    required this.dispositionCode,
    required this.quantity,
    required this.warehouseId,
    required this.sourcePlanItemId,
    required this.executionSegmentId,
    required this.planId,
    required this.reportMakerId,
    required this.status,
    this.planNo,
    this.sourceReportNo,
    this.materialAnalysisId,
    this.cycleId,
    this.drawId,
    this.drawNo,
    this.drawStatus,
    this.drawIssueStatus,
    this.blockedReason,
  });

  final String taskId;
  final String authorizationId;
  final String dispositionCode;
  final double quantity;
  final String warehouseId;
  final String sourcePlanItemId;
  final String executionSegmentId;
  final String planId;
  final String? planNo;
  final String reportMakerId;
  final String? sourceReportNo;
  final String? materialAnalysisId;
  final String? cycleId;
  final String? drawId;
  final String? drawNo;
  final int? drawStatus;
  final int? drawIssueStatus;
  final String status;
  final String? blockedReason;

  String get dispositionLabel => switch (dispositionCode) {
    'SCRAP' => '报废补产',
    'REJECT' => '拒收补产',
    _ => '品质补产',
  };

  bool get isTerminal => status == 'READY' || status == 'CANCELLED';

  factory ProductionFqcReplenishmentMaterialTask.fromJson(
    Map<String, dynamic> json,
  ) => ProductionFqcReplenishmentMaterialTask(
    taskId: json['taskId'] as String? ?? '',
    authorizationId: json['authorizationId'] as String? ?? '',
    dispositionCode: json['dispositionCode'] as String? ?? '',
    quantity: (json['quantity'] as num?)?.toDouble() ?? 0,
    warehouseId: json['warehouseId'] as String? ?? '',
    sourcePlanItemId: json['sourcePlanItemId'] as String? ?? '',
    executionSegmentId: json['executionSegmentId'] as String? ?? '',
    planId: json['planId'] as String? ?? '',
    planNo: json['planNo'] as String?,
    reportMakerId: json['reportMakerId'] as String? ?? '',
    sourceReportNo: json['sourceReportNo'] as String?,
    materialAnalysisId: json['materialAnalysisId'] as String?,
    cycleId: json['cycleId'] as String?,
    drawId: json['drawId'] as String?,
    drawNo: json['drawNo'] as String?,
    drawStatus: (json['drawStatus'] as num?)?.toInt(),
    drawIssueStatus: (json['drawIssueStatus'] as num?)?.toInt(),
    status: json['status'] as String? ?? 'AWAITING_ANALYSIS',
    blockedReason: json['blockedReason'] as String?,
  );
}
