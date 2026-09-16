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
    this.receivingGoodsCode,
    this.receivingGoodsName,
    this.requiredQty = 0,
    this.alreadyCoveredQty = 0,
  });

  final String demandId;
  final String executionSegmentId;
  final String? executionSegmentCode;
  final String? planId;
  final String? planNo;

  /// 转送的料本身（与本报工行同货品）。
  final String? goodsCode;
  final String? goodsName;
  final String? colorName;
  final String? unitName;

  /// 接收方(父件工单)正在生产的产品——车间认「投给谁」认的是这个。
  final String? receivingGoodsCode;
  final String? receivingGoodsName;

  final double requiredQty;
  final double alreadyCoveredQty;

  /// 这条需求还差多少没被直送覆盖，也是本次直送的上限。
  final double remainingQty;

  /// 父件产品名 + 编号，缺哪项少哪项。
  String get receivingGoodsLabel {
    final name = receivingGoodsName?.trim();
    final code = receivingGoodsCode?.trim();
    return [
      if (name != null && name.isNotEmpty) name,
      if (code != null && code.isNotEmpty) code,
    ].join(' ');
  }

  /// 收起态(选中后格子里的单行)：父件产品 + 还差多少。工单号放下拉第二行，
  /// 不挤占这一行——车间认料认的是产品，不是工单号。
  String get label {
    final head = receivingGoodsLabel.isEmpty
        ? (executionSegmentCode?.trim().isNotEmpty == true
              ? executionSegmentCode!.trim()
              : (planNo ?? '上层工单'))
        : receivingGoodsLabel;
    return '$head · 还差 ${_number(remainingQty)} ${unitName ?? ''}'.trim();
  }

  /// 下拉第二行：工单号 · 还差多少。
  String get secondaryLabel {
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
      receivingGoodsCode: json['receivingGoodsCode'] as String?,
      receivingGoodsName: json['receivingGoodsName'] as String?,
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

/// 候选接口的完整返回：候选列表 + 空候选的原因标记。
///
/// [lineSideWarehouseMissing]=true 表示同车间明明有还缺料的上层工单，
/// 只是本车间没有与收料需求同主仓的线边仓——界面应提示先建线边仓，
/// 而不是让车间以为「没有可投的上层工单」。
class DirectTransferCandidatesResult {
  const DirectTransferCandidatesResult({
    required this.candidates,
    this.lineSideWarehouseMissing = false,
  });

  final List<ProductionDirectTransferCandidate> candidates;
  final bool lineSideWarehouseMissing;

  factory DirectTransferCandidatesResult.fromJson(Map<String, dynamic> json) {
    final rows = json['candidates'];
    return DirectTransferCandidatesResult(
      candidates: rows is List
          ? rows
                .map(
                  (e) => ProductionDirectTransferCandidate.fromJson(
                    e as Map<String, dynamic>,
                  ),
                )
                .toList(growable: false)
          : const [],
      lineSideWarehouseMissing:
          (json['lineSideWarehouseMissing'] as bool?) ?? false,
    );
  }
}
