/// 报工页「转下一道工序」的候选工单(V584/V585)。
///
/// 服务端只列**同车间**、同货品同颜色、还缺料的上层工单：跨车间必须走仓库，
/// 数据库守卫也会拒。已开工且需求已领齐的段不列——料投过去挂不上，只会变成呆料。
class ProductionDirectTransferCandidate {
  const ProductionDirectTransferCandidate({
    required this.demandId,
    required this.executionSegmentId,
    required this.remainingQty,
    this.executionSegmentCode,
    this.planId,
    this.planNo,
    this.goodsCode,
    this.goodsName,
    this.colorName,
    this.unitName,
    this.requiredQty = 0,
    this.alreadyCoveredQty = 0,
  });

  final String demandId;
  final String executionSegmentId;
  final String? executionSegmentCode;
  final String? planId;
  final String? planNo;
  final String? goodsCode;
  final String? goodsName;
  final String? colorName;
  final String? unitName;
  final double requiredQty;
  final double alreadyCoveredQty;

  /// 这条需求还差多少没被直送覆盖，也是本次直送的上限。
  final double remainingQty;

  /// 下拉里的一行：工单号 + 还差多少。计划号放副标题，别把一行撑爆。
  String get label {
    final segment = executionSegmentCode?.trim();
    final head = segment == null || segment.isEmpty
        ? (planNo ?? '上层工单')
        : segment;
    return '$head · 还差 ${_number(remainingQty)} ${unitName ?? ''}'.trim();
  }

  factory ProductionDirectTransferCandidate.fromJson(
    Map<String, dynamic> json,
  ) {
    double number(String key) => (json[key] as num?)?.toDouble() ?? 0;
    return ProductionDirectTransferCandidate(
      demandId: json['demandId'] as String,
      executionSegmentId: json['executionSegmentId'] as String,
      executionSegmentCode: json['executionSegmentCode'] as String?,
      planId: json['planId'] as String?,
      planNo: json['planNo'] as String?,
      goodsCode: json['goodsCode'] as String?,
      goodsName: json['goodsName'] as String?,
      colorName: json['colorName'] as String?,
      unitName: json['unitName'] as String?,
      requiredQty: number('requiredQty'),
      alreadyCoveredQty: number('alreadyCoveredQty'),
      remainingQty: number('remainingQty'),
    );
  }
}

String _number(double value) => value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value
          .toStringAsFixed(4)
          .replaceFirst(RegExp(r'0+$'), '')
          .replaceFirst(RegExp(r'\.$'), '');
