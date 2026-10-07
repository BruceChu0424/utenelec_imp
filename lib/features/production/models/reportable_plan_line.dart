import 'production_exact_quantity.dart';

double? _asDouble(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

/// 后端报工来源读侧的一行。
///
/// 合并排产时同一 [planItemId] 会按不同 [orderItemId] 展开，报工保存必须
/// 同时提交两个 id，避免把完成量记到错误的销售订单。
class ReportablePlanLine {
  const ReportablePlanLine({
    required this.planItemId,
    required this.planNo,
    required this.goodsId,
    required this.maxReportQty,
    this.planId,
    this.executionSegmentId,
    this.executionSegmentSalesAllocationId,
    this.executionSegmentCode,
    this.executionSegmentStatus,
    this.executionSegmentVersion,
    this.orderItemId,
    this.productNo,
    this.goodsCode,
    this.goodsName,
    this.goodsSpec,
    this.colorId,
    this.colorName,
    this.unitId,
    this.unitName,
    this.unitRate,
    this.unitRateExact,
    this.maxReportQtyExact,
    this.plannedQty,
    this.producedQty,
    this.remainingPlanQty,
    this.allocatedQty,
    this.linkedProducedQty,
    this.orderNo,
    this.orderQty,
    this.clientName,
    this.departmentId,
    this.workshopName,
    this.planBeginDate,
    this.planEndDate,
    this.deliveryDate,
    this.fqcRecoveryAuthorizationId,
    this.fqcRecoveryDispositionCode,
    this.fqcRecoveryAvailableQty = 0,
    this.fqcSourceInspectionId,
    this.fqcSourceReportItemId,
    this.fqcSourceReportNo,
    this.fqcRecoveryRequiresMaterial = false,
    this.allowActualOverproduction = false,
    this.remainingActualSurplusQty,
    this.pendingSupplementQty,
  });

  final String planItemId;
  final String? planId;
  final String? executionSegmentId;
  final String? executionSegmentSalesAllocationId;
  final String? executionSegmentCode;
  final String? executionSegmentStatus;
  final int? executionSegmentVersion;
  final String? orderItemId;
  final String planNo;
  final String? productNo;
  final String goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? goodsSpec;
  final String? colorId;
  final String? colorName;
  final String? unitId;
  final String? unitName;
  final double? unitRate;
  final String? unitRateExact;
  final String? maxReportQtyExact;
  String? get unitRateText =>
      productionExactQuantityText(unitRateExact ?? unitRate, scale: 6);
  String? get maxReportQtyText =>
      productionExactQuantityText(maxReportQtyExact ?? maxReportQty);
  final double? plannedQty;
  final double? producedQty;
  final double? remainingPlanQty;
  final double? allocatedQty;
  final double? linkedProducedQty;
  final double maxReportQty;
  final String? orderNo;
  final double? orderQty;
  final String? clientName;
  final String? departmentId;
  final String? workshopName;
  final String? planBeginDate;
  final String? planEndDate;
  final String? deliveryDate;
  final String? fqcRecoveryAuthorizationId;
  final String? fqcRecoveryDispositionCode;
  final double fqcRecoveryAvailableQty;
  final String? fqcSourceInspectionId;
  final String? fqcSourceReportItemId;
  final String? fqcSourceReportNo;
  final bool fqcRecoveryRequiresMaterial;

  /// 服务端明确允许实际超产；旧服务端和品质恢复默认继续遵守上限。
  final bool allowActualOverproduction;

  /// 剩余有效公共超产额度（服务端已扣「已批准未续报」的固定追加量）。
  final double? remainingActualSurplusQty;

  /// 2026-10-06：本来源工单已批准、尚未续报承接的固定追加量合计——它占住了
  /// 公共超产额度，超出的量只能从「固定追加量·续报」入口申报。
  final double? pendingSupplementQty;

  bool get isFqcRecovery => fqcRecoveryAuthorizationId?.isNotEmpty == true;

  /// Drafts reserve reportable quota, but cannot make a task's last batch complete.
  double? get remainingCompletionQty {
    final planned = plannedQty;
    final produced = producedQty;
    if (planned == null ||
        produced == null ||
        !planned.isFinite ||
        !produced.isFinite) {
      return null;
    }
    final remaining = planned - produced;
    return remaining > 0 ? remaining : 0;
  }

  bool get canReport =>
      !fqcRecoveryRequiresMaterial &&
      (maxReportQty > 0.000001 ||
          (allowActualOverproduction && !isFqcRecovery));

  String? get fqcRecoveryLabel {
    if (!isFqcRecovery) return null;
    return switch (fqcRecoveryDispositionCode) {
      'REWORK' => '返工再检',
      'SCRAP' => '报废补产',
      'REJECT' => '拒收补产',
      _ => 'FQC恢复',
    };
  }

  String? get blockedReason {
    if (!fqcRecoveryRequiresMaterial) return null;
    return '${fqcRecoveryLabel ?? '补产'}尚未完成新增物料齐套和仓库发料，当前不能报工';
  }

  factory ReportablePlanLine.fromJson(
    Map<String, dynamic> json,
  ) => ReportablePlanLine(
    planItemId: json['planItemId'] as String,
    planId: json['planId'] as String?,
    executionSegmentId: json['executionSegmentId'] as String?,
    executionSegmentSalesAllocationId:
        json['executionSegmentSalesAllocationId'] as String?,
    executionSegmentCode: json['executionSegmentCode'] as String?,
    executionSegmentStatus: json['executionSegmentStatus'] as String?,
    executionSegmentVersion: (json['executionSegmentVersion'] as num?)?.toInt(),
    orderItemId: json['orderItemId'] as String?,
    planNo: json['planNo'] as String,
    productNo: json['productNo'] as String?,
    goodsId: json['goodsId'] as String,
    goodsCode: json['goodsCode'] as String?,
    goodsName: json['goodsName'] as String?,
    goodsSpec: json['goodsSpec'] as String?,
    colorId: json['colorId'] as String?,
    colorName: json['colorName'] as String?,
    unitId: json['unitId'] as String?,
    unitName: json['unitName'] as String?,
    unitRate: _asDouble(json['unitRate']),
    unitRateExact: productionExactQuantityText(
      json['unitRateExact'] ?? json['unitRate'],
      scale: 6,
    ),
    maxReportQtyExact: productionExactQuantityText(
      json['maxReportQtyExact'] ?? json['maxReportQty'],
    ),
    plannedQty: _asDouble(json['plannedQty']),
    producedQty: _asDouble(json['producedQty']),
    remainingPlanQty: _asDouble(json['remainingPlanQty']),
    allocatedQty: _asDouble(json['allocatedQty']),
    linkedProducedQty: _asDouble(json['linkedProducedQty']),
    maxReportQty: _asDouble(json['maxReportQty']) ?? 0,
    orderNo: json['orderNo'] as String?,
    orderQty: _asDouble(json['orderQty']),
    clientName: json['clientName'] as String?,
    departmentId: json['departmentId'] as String?,
    workshopName: json['workshopName'] as String?,
    planBeginDate: json['planBeginDate'] as String?,
    planEndDate: json['planEndDate'] as String?,
    deliveryDate: json['deliveryDate'] as String?,
    fqcRecoveryAuthorizationId: json['fqcRecoveryAuthorizationId'] as String?,
    fqcRecoveryDispositionCode: json['fqcRecoveryDispositionCode'] as String?,
    fqcRecoveryAvailableQty: _asDouble(json['fqcRecoveryAvailableQty']) ?? 0,
    fqcSourceInspectionId: json['fqcSourceInspectionId'] as String?,
    fqcSourceReportItemId: json['fqcSourceReportItemId'] as String?,
    fqcSourceReportNo: json['fqcSourceReportNo'] as String?,
    fqcRecoveryRequiresMaterial: json['fqcRecoveryRequiresMaterial'] == true,
    allowActualOverproduction: json['allowActualOverproduction'] == true,
    remainingActualSurplusQty: _asDouble(json['remainingActualSurplusQty']),
    pendingSupplementQty: _asDouble(json['pendingSupplementQty']),
  );
}

/// 精确执行子任务只返回一个权威分摊时，可以跳过重复选择面板。
/// 多个订单或公共备货来源仍须由用户确认，不能默认取第一条导致串单。
ReportablePlanLine? uniqueReportablePlanLine(
  List<ReportablePlanLine> items,
  int total,
) => total == 1 && items.length == 1 ? items.single : null;
