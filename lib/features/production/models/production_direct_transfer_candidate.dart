/// 报工页「转下一道工序」的候选工单(V584/V585/V595)。
///
/// 服务端只列**同车间**、同货品同颜色、还缺料的上层工单：跨车间必须走仓库，
/// 数据库守卫也会拒。等待/齐套/已派工的上层工单，以及**持续生产中**的上层工单
/// 都可以收；普通已开工的段不列——料投过去挂不上，只会变成呆料。
class ProductionDirectTransferCandidate {
  const ProductionDirectTransferCandidate({
    required this.demandId,
    required this.executionSegmentId,
    required this.remainingQty,
    this.executionSegmentCode,
    this.executionSegmentStatus,
    this.continuousSupply = false,
    this.planId,
    this.planNo,
    this.goodsCode,
    this.goodsName,
    this.colorName,
    this.unitName,
    this.receivingGoodsId,
    this.receivingGoodsCode,
    this.receivingGoodsName,
    this.requiredQty = 0,
    this.alreadyCoveredQty = 0,
  });

  final String demandId;
  final String executionSegmentId;
  final String? executionSegmentCode;
  final String? executionSegmentStatus;

  /// 接收方是「持续生产」工单(V595)：这批料审核后立刻补投给它，不看齐套。
  final bool continuousSupply;
  final String? planId;
  final String? planNo;

  /// 转送的料本身（与本报工行同货品）。
  final String? goodsCode;
  final String? goodsName;
  final String? colorName;
  final String? unitName;

  /// 接收方(父件工单)正在生产的产品——车间认「投给谁」认的是这个。
  final String? receivingGoodsId;
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

  /// 下拉第二行：工单号 · 还差多少(持续生产中的工单另加标注)。
  String get secondaryLabel {
    final segment = executionSegmentCode?.trim();
    final head = segment == null || segment.isEmpty
        ? (planNo ?? '上层工单')
        : segment;
    final tail = continuousSupply ? ' · 持续生产中' : '';
    return '$head · 还差 ${_number(remainingQty)} ${unitName ?? ''}'.trim() +
        tail;
  }

  factory ProductionDirectTransferCandidate.fromJson(
    Map<String, dynamic> json,
  ) {
    double number(String key) => (json[key] as num?)?.toDouble() ?? 0;
    return ProductionDirectTransferCandidate(
      demandId: json['demandId'] as String,
      executionSegmentId: json['executionSegmentId'] as String,
      executionSegmentCode: json['executionSegmentCode'] as String?,
      executionSegmentStatus: json['executionSegmentStatus'] as String?,
      continuousSupply: json['continuousSupply'] == true,
      planId: json['planId'] as String?,
      planNo: json['planNo'] as String?,
      goodsCode: json['goodsCode'] as String?,
      goodsName: json['goodsName'] as String?,
      colorName: json['colorName'] as String?,
      unitName: json['unitName'] as String?,
      receivingGoodsId: json['receivingGoodsId'] as String?,
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

/// 候选接口的完整返回：候选列表 + 上次报工的记忆(V595)。
///
/// [lastDestination]/[lastReceivingGoodsId]：本车间上一次报这个货品时选的去向与
/// 投给的父件产品。报工页据此预填并标黄提醒核对——去向大多数时候不变，
/// 但以前每次都要人重新选一遍。线边仓缺失(V584 的 lineSideWarehouseMissing)
/// 不再是空候选的原因：V595 起线边仓由服务端自动配置。
class DirectTransferCandidatesResult {
  const DirectTransferCandidatesResult({
    required this.candidates,
    this.lastDestination,
    this.lastReceivingGoodsId,
    this.lastReceivingGoodsCode,
    this.lastReceivingGoodsName,
  });

  final List<ProductionDirectTransferCandidate> candidates;

  /// 'WAREHOUSE' / 'WORKSHOP'；没报过为 null。
  final String? lastDestination;
  final String? lastReceivingGoodsId;
  final String? lastReceivingGoodsCode;
  final String? lastReceivingGoodsName;

  bool get hasMemory => lastDestination != null;

  /// 记忆指向的候选：只有恰好一个候选的父件产品与上次相同才算命中，
  /// 两个同产品工单并存时不替人猜。
  ProductionDirectTransferCandidate? get rememberedCandidate {
    final goodsId = lastReceivingGoodsId;
    if (goodsId == null || goodsId.isEmpty) return null;
    final matches = candidates
        .where((candidate) => candidate.receivingGoodsId == goodsId)
        .toList(growable: false);
    return matches.length == 1 ? matches.single : null;
  }

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
      lastDestination: json['lastDestination'] as String?,
      lastReceivingGoodsId: json['lastReceivingGoodsId'] as String?,
      lastReceivingGoodsCode: json['lastReceivingGoodsCode'] as String?,
      lastReceivingGoodsName: json['lastReceivingGoodsName'] as String?,
    );
  }
}
