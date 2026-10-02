/// 报工页「转下一道工序」的候选工单(V584/V585/V595)。
///
/// 能不能送、还差多少只由服务端的一份判定给出(V736/ADR-127)：这里只收可送的上层工单，
/// 本端不复写任何资格条件；一张报工里多行之间的扣减在 daily_output_allocation.dart 一处算。
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

  /// 本来源可直送的基础数量：接收需求未覆盖量与本生产来源剩余责任量的较小值。
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

  /// 去向下拉条目(V736/ADR-127)：工单号 · 父件产品 · 还差多少([roomBase] = 本行还能分给它的基本数量)。
  String optionLabel(double roomBase) {
    final segment = executionSegmentCode?.trim();
    final head = segment == null || segment.isEmpty
        ? (planNo ?? '上层工单')
        : segment;
    final room = roomBase > 0 ? roomBase : 0.0;
    return [
      head,
      if (receivingGoodsLabel.isNotEmpty) receivingGoodsLabel,
      '还差 ${_number(room)}${unitName == null ? '' : ' $unitName'}',
      if (continuousSupply) '持续生产中',
    ].join(' · ');
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

/// 不能转时悬停提示的统一开头(与服务端审核报错、数据库守卫同一句)。
const directTransferUnavailablePrefix = '无法转到下一道工序：';

/// 候选读取失败时的提示：读取失败不等于「没有上层工单」。
const directTransferLoadFailedText = '转给工单候选读取失败，请刷新后重试';

/// 结构上是本工单的上层、但现在不能收的工单(V736/ADR-127)：报工页下拉里置灰并用红字写明原因。
class ProductionDirectTransferBlockedTarget {
  const ProductionDirectTransferBlockedTarget({
    required this.demandId,
    required this.reason,
    this.executionSegmentId,
    this.executionSegmentCode,
    this.planNo,
    this.receivingGoodsId,
    this.receivingGoodsCode,
    this.receivingGoodsName,
    this.reasonCode,
  });

  final String demandId;
  final String? executionSegmentId;
  final String? executionSegmentCode;
  final String? planNo;
  final String? receivingGoodsId;
  final String? receivingGoodsCode;
  final String? receivingGoodsName;

  /// 服务端给的原因大白话(例如「上层工单 ZX… 在二车间，跨车间必须送入仓库」)。
  final String reason;

  /// 原因的机器码，只用于判断与测试，界面不显示。
  final String? reasonCode;

  /// 下拉条目：工单号 · 父件产品 · 原因。
  String get optionLabel {
    final segment = executionSegmentCode?.trim();
    final head = segment == null || segment.isEmpty
        ? (planNo ?? '上层工单')
        : segment;
    final product = [
      if (receivingGoodsName?.trim().isNotEmpty == true)
        receivingGoodsName!.trim(),
      if (receivingGoodsCode?.trim().isNotEmpty == true)
        receivingGoodsCode!.trim(),
    ].join(' ');
    return [head, if (product.isNotEmpty) product, reason].join(' · ');
  }

  factory ProductionDirectTransferBlockedTarget.fromJson(
    Map<String, dynamic> json,
  ) => ProductionDirectTransferBlockedTarget(
    demandId: json['demandId'] as String,
    executionSegmentId: json['executionSegmentId'] as String?,
    executionSegmentCode: json['executionSegmentCode'] as String?,
    planNo: json['planNo'] as String?,
    receivingGoodsId: json['receivingGoodsId'] as String?,
    receivingGoodsCode: json['receivingGoodsCode'] as String?,
    receivingGoodsName: json['receivingGoodsName'] as String?,
    reasonCode: json['reasonCode'] as String?,
    reason: json['reason'] as String? ?? '',
  );
}

/// 候选接口的完整返回：可送的上层工单(先急后缓) + 不能收的上层工单 + 不可转原因(V736/ADR-127)。
///
/// [unavailableReason]：一个可送的上层工单都没有时，服务端给出最接近可送的那条原因
/// (例如「HV5ZJ012 是委外件：……」「上层工单 ZX… 在二车间，跨车间必须送入仓库」)。
///
/// 默认去向不再按上次报工记忆替人选：报工页按 [candidates] 的先急后缓次序逐个分满，其余送入仓库。
class DirectTransferCandidatesResult {
  const DirectTransferCandidatesResult({
    required this.candidates,
    this.blockedTargets = const [],
    this.unavailableReason,
    this.unavailableReasonCode,
    this.receiverLimit = 1 << 30,
    this.loadFailed = false,
  });

  /// 候选读取失败：不能当成「没有上层工单」，也不能替人改去向。
  const DirectTransferCandidatesResult.loadFailed()
    : this(candidates: const [], loadFailed: true);

  /// 可送的上层工单，已按先急后缓排好。
  final List<ProductionDirectTransferCandidate> candidates;

  /// 结构上是上层、但现在不能收的工单(同一次序)。
  final List<ProductionDirectTransferBlockedTarget> blockedTargets;

  /// 没有可送的上层工单时服务端给的原因(大白话)；有候选时为空。
  final String? unavailableReason;

  /// 原因的机器码，只用于判断与测试，界面不显示。
  final String? unavailableReasonCode;

  /// 一行报工最多同时转给几个上层工单(服务端同一个常量)。
  final int receiverLimit;

  final bool loadFailed;

  /// 「产出去向」格的提示：不可转原因用于悬停，读取失败直接报错；有候选时为空。
  String? get blockedText {
    if (loadFailed) return directTransferLoadFailedText;
    if (candidates.isNotEmpty) return null;
    final reason = unavailableReason?.trim();
    // 服务端总会给原因；万一缺了也只说「不能转」，不编造原因。
    return reason == null || reason.isEmpty
        ? '无法转到下一道工序'
        : '$directTransferUnavailablePrefix$reason';
  }

  factory DirectTransferCandidatesResult.fromJson(Map<String, dynamic> json) {
    final rows = json['candidates'];
    final blocked = json['blockedTargets'];
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
      blockedTargets: blocked is List
          ? blocked
                .map(
                  (e) => ProductionDirectTransferBlockedTarget.fromJson(
                    e as Map<String, dynamic>,
                  ),
                )
                .toList(growable: false)
          : const [],
      unavailableReason: json['unavailableReason'] as String?,
      unavailableReasonCode: json['unavailableReasonCode'] as String?,
      receiverLimit: (json['receiverLimit'] as num?)?.toInt() ?? 1 << 30,
    );
  }
}
