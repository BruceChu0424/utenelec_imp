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
  });

  final String planItemId;
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

  factory ReportablePlanLine.fromJson(Map<String, dynamic> json) =>
      ReportablePlanLine(
        planItemId: json['planItemId'] as String,
        executionSegmentId: json['executionSegmentId'] as String?,
        executionSegmentSalesAllocationId:
            json['executionSegmentSalesAllocationId'] as String?,
        executionSegmentCode: json['executionSegmentCode'] as String?,
        executionSegmentStatus: json['executionSegmentStatus'] as String?,
        executionSegmentVersion: (json['executionSegmentVersion'] as num?)
            ?.toInt(),
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
      );
}
