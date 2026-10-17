// 生产日报明细可编辑表的行模型 + 列定义（UtenEditableGrid 用）。
//
// 日报记录非金额生产计量事实：完工申报量及可选实际总重量。
// 客户端单价/金额不是计件工资权威，已从操作界面移除。
// DailyGridRow：货品(选择)/完工申报量/实际重量；颜色选货品后自动回填（只读）、
// 单位回填后作数量输入框后缀（2026-10-10 数量内联口径）；
// 精确来源子任务链接 + 备注。历史完结事实保留，不再作为新报工入口。
import 'package:flutter/material.dart';
import 'package:uten_imp/components/inputs/uten_field_placeholder.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import '../../../shared/presentation/workflow_field_guidance.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';

import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/formatters/quantity_display.dart';
import '../../../shared/widgets/uten_tree_table_cell.dart';
import '../models/daily_output_allocation.dart'
    show outputAllocationQuantityText;
import '../models/production_direct_transfer_candidate.dart';
import '../models/production_daily_report.dart';
import '../models/production_exact_quantity.dart';
import '../repositories/production_material_repository.dart';

final _quantityTypingPattern = RegExp(r'^\d*\.?\d{0,4}$');

/// 数量输入保留原文；不合格的按键保留原值，不截断为另一数量。
final productionQuantityInputFormatter = TextInputFormatter.withFunction(
  (oldValue, newValue) =>
      _quantityTypingPattern.hasMatch(newValue.text) ? newValue : oldValue,
);

/// One editable fact per demand, shared by all displayed output slices.
class DailyMaterialInput {
  final used = TextEditingController();
  final ValueNotifier<bool> autofilled = ValueNotifier<bool>(false);
  String? autofillText;
  double? manualRatio;
  bool manuallyEdited = false;

  void dispose() {
    used.dispose();
    autofilled.dispose();
  }
}

/// 成品行下面的两个子行分组（2026-10-10 报工页口径）：「产出去向」与
/// 「子件用料」各自独立折叠——两个分组头各带自己的展开/收起钮，互不影响，
/// 也可以同时展开。
enum DailyRowGroup { allocations, materials }

/// 生产日报明细行。货品用 ValueNotifier（点选后单元格自动刷新）；
/// 完工量是生产声明；颜色为来源任务冻结值，单位作数量输入框后缀。
class DailyGridRow extends EditableGridRow {
  DailyGridRow({String? localRowId})
    : localRowId = localRowId ?? const Uuid().v4();

  /// Local draft identity only. Copies get a fresh ID; this is never submitted
  /// as a server item ID or inferred from goods/source/visible row position.
  final String localRowId;

  /// Read-only accepted item projection, supplied only by the saved report.
  /// Never recompute its destination from today's transfer availability.
  String? acceptedDestinationLabel;

  final ValueNotifier<GoodsOption?> goodsNotifier = ValueNotifier<GoodsOption?>(
    null,
  );
  GoodsOption? get goods => goodsNotifier.value;
  set goods(GoodsOption? v) => goodsNotifier.value = v;

  final TextEditingController qty = TextEditingController(); // 完工量
  bool qtyNeedsVerification = false;
  bool defectQtyNeedsVerification = false;

  /// 不良数(ADR-129)：只记录，不影响完工申报量、库存与产量分流；空 = 0。
  final TextEditingController defectQty = TextEditingController();
  final TextEditingController weight = TextEditingController(); // 本行实际总重量
  final TextEditingController planNo = TextEditingController(); // 关联生产计划号
  final TextEditingController remark = TextEditingController();
  final TextEditingController overLimitReason = TextEditingController();

  /// 权威报工来源。合并排产必须同时带计划行和销售订单行，禁止只靠计划号猜分摊。
  String? planItemId;
  String? planId;
  String? executionSegmentId;
  String? executionSegmentSalesAllocationId;
  String? executionSegmentCode;
  int? executionSegmentVersion;
  String? fqcRecoveryAuthorizationId;
  String? fqcRecoveryDispositionCode;
  String? fqcSourceReportNo;
  String? salesOrderItemId;
  String? salesOrderNo;
  String? clientName;
  double? unitRate;
  String? unitRateExact;
  String? get unitRateText =>
      productionExactQuantityText(unitRateExact ?? unitRate, scale: 6);
  double? orderQty;
  double? maxReportQty;
  String? maxReportQtyExact;
  String? get maxReportQtyText =>
      productionExactQuantityText(maxReportQtyExact ?? maxReportQty);
  bool allowActualOverproduction = false;

  /// 剩余有效公共超产额度（服务端已扣「已批准未续报」的固定追加量）。
  double? remainingActualSurplusQty;
  String? remainingActualSurplusQtyExact;

  /// 本来源工单已批准、尚未续报承接的固定追加量合计；>0 时上限提示指路续报入口。
  double? pendingSupplementQty;
  String? pendingSupplementQtyExact;
  String? get pendingSupplementQtyText => productionExactQuantityText(
    pendingSupplementQtyExact ?? pendingSupplementQty ?? 0,
  );
  String? supplementRequestId;
  String? supplementProofId;
  double? supplementApprovedActualQty;
  String? supplementApprovedActualQtyExact;
  String? get supplementApprovedActualQtyText => productionExactQuantityText(
    supplementApprovedActualQtyExact ?? supplementApprovedActualQty,
  );
  bool get hasFixedSupplement =>
      !isFqcRecovery &&
      (supplementProofId != null ||
          (supplementRequestId != null && supplementApprovedActualQty != null));

  /// 2026-10-06 口径：完工申报上限 = 计划剩余 + 剩余有效超产额度。
  /// 已批准未承接的固定追加量已由服务端从额度里扣除——追加量只能走
  /// 「固定追加量·续报」入口，原任务行不再无上限。固定追加批次行另由
  /// hasFixedSupplement 的整批锁量校验，不在这里。
  double? get reportQtyCap {
    final text = reportQtyCapText;
    return text == null ? null : double.parse(text);
  }

  bool get hasReportQtyCap {
    if (hasFixedSupplement) return false;
    if (maxReportQty != null || maxReportQtyExact != null) return true;
    if (isFqcRecovery || !allowActualOverproduction) return false;
    final surplus = remainingActualSurplusQtyExact ?? remainingActualSurplusQty;
    if (surplus == null) return false;
    final units = productionExactQuantityUnits(surplus);
    return units == null || units > BigInt.zero;
  }

  String? get reportQtyCapText {
    if (!hasReportQtyCap) return null;
    if (isFqcRecovery || !allowActualOverproduction) return maxReportQtyText;
    final planned = maxReportQty == null && maxReportQtyExact == null
        ? BigInt.zero
        : productionExactQuantityUnits(maxReportQtyText);
    final surplus = productionExactQuantityUnits(
      remainingActualSurplusQtyExact ?? remainingActualSurplusQty ?? 0,
    );
    if (planned == null || surplus == null) return null;
    return productionQuantityTextFromUnits(planned + surplus);
  }

  /// 普通生产可如实登记超限量；品质恢复与历史固定追加仍按原授权执行。
  bool get canRecordOverLimit =>
      allowActualOverproduction && !isFqcRecovery && !hasFixedSupplement;

  double get estimatedOverLimitQty {
    final text = estimatedOverLimitQtyText;
    return text == null ? 0 : double.parse(text);
  }

  String? get estimatedOverLimitQtyText {
    final cap = productionExactQuantityUnits(reportQtyCapText);
    final actual = productionExactQuantityUnits(
      qty.text.trim().replaceFirst(RegExp(r'\.$'), ''),
    );
    if (!canRecordOverLimit || cap == null || actual == null) {
      return null;
    }
    return productionQuantityTextFromUnits(
      actual > cap ? actual - cap : BigInt.zero,
    );
  }

  /// Remaining output target, distinct from this delivery's material capacity.
  double? remainingPlanQty;
  String? remainingPlanQtyExact;
  bool legacyManual = false;

  // ===== V583 物料子行 / V736 去向分配子行：报工、去向与实际用料合并到同一张表 =====
  // 一张表只能有一个泛型行类型，所以成品行与两种子行共用本类，由 [depth] 区分：
  // 0 = 成品报工行(原有全部字段)，1 = 挂在它下面的子行——去向分配子行([allocationParent] 非空)
  // 或物料子行(其余)。各列的 cellBuilder 按行种分支，用不到的格返回空。

  /// 0 = 成品报工行；1 = 挂在成品行下面的分组头；2 = 挂在分组头下面的子行。
  int depth = 0;

  /// 挂在成品行下面的子行(分组头、去向分配或物料)。成品行的校验、行号、勾选
  /// 都只看 depth=0 的行。
  bool get isSubRow => depth > 0;

  // ===== 子行分组头（产出去向 / 子件用料）：两个独立折叠分组的分组头行 =====
  /// 非空 = 本行是分组头行；[groupParent] 指回所属成品行，[groupChildCount]
  /// 由编辑页每次重排时刷新（收起态的「N」徽章与列宽测量用）。
  DailyRowGroup? groupHeader;
  DailyGridRow? groupParent;
  int groupChildCount = 0;

  /// 非分组头行才可能是去向/物料子行。
  bool get isGroupHeaderRow => groupHeader != null;

  /// 两个分组头对象挂在成品行上复用（重排换行不丢控制器）；分组消失时由
  /// 编辑页释放。null = 该分组当前不存在（没有去向可分 / 没有台账行）。
  DailyGridRow? allocationsGroupHeader;
  DailyGridRow? materialsGroupHeader;

  /// 物料子行的来源台账行(领料量、可继续登记量、单位、颜色都在里面)。
  ProductionMaterialClearanceRow? material;

  /// 物料子行所属的成品行。删成品行时连带删掉它，不留孤儿。
  DailyGridRow? materialParent;

  /// 本子行是否由自己负责提交。同一个执行工单出现在多个成品行时，它的物料只有
  /// 一份额度：第一处 owns=true 可填，其余是只读镜像，避免两行各自当满额填。
  bool materialOwnsInput = true;

  /// 沿用前批已领物料：该子行的料挂在前批原领料段上，不是本次报工的段。
  bool materialShared = false;

  /// 当前账号对该物料所属工单没有 production_material:settle 权限：只读，不参与必填。
  bool materialReadOnly = false;

  /// 本次实际用料(基本量)。允许 0——「这批料一点没用」是合法事实。
  DailyMaterialInput _materialInput = DailyMaterialInput();
  bool _ownsMaterialInput = true;
  DailyMaterialInput get materialInput => _materialInput;
  TextEditingController get materialUsed => _materialInput.used;

  void bindMaterialInput(DailyMaterialInput input) {
    if (identical(_materialInput, input)) return;
    if (_ownsMaterialInput) _materialInput.dispose();
    _materialInput = input;
    _ownsMaterialInput = false;
  }

  // ===== V736/ADR-127 产出去向分配：一行实际产量逐个分给上层工单，其余送入仓库 =====
  // 成品行下面挂「去向分配」子行，每条 = (去向: 某个上层工单 或 送入仓库, 数量)。
  // 系统按先急后缓给出建议(黄框)，工人可改任一条；合计始终等于本行实际产量，
  // 重排只在 daily_output_allocation.dart 一处算。服务端每个上层工单拆一条转送明细。

  /// 成品行：本行可送的上层工单(先急后缓)；由服务端唯一判定给出。
  List<ProductionDirectTransferCandidate> directTransferCandidates = const [];

  /// 成品行：结构上是上层但现在不能收的工单(下拉置灰、红字写原因)。
  List<ProductionDirectTransferBlockedTarget> directTransferBlockedTargets =
      const [];

  /// 成品行：一行最多同时转给几个上层工单(服务端给出)。
  int directTransferReceiverLimit = 1 << 30;
  int directTransferRequestVersion = 0;

  /// 成品行「产出去向」格的悬停原因：「无法转到下一道工序：<服务端原因>」；
  /// 候选读取失败时仍在格内显示错误提示。
  /// 为空 = 有可送的上层工单，或还没读过候选(没选来源/货品)。
  String? directTransferBlockedText;

  /// 最近一次候选读取失败：此时不知道能不能转，不替人改已定的去向。
  bool directTransferLoadFailed = false;

  /// 候选已读到且一个可送的都没有：只能送入仓库，去向子行不给下拉。
  bool get directTransferUnavailable =>
      directTransferBlockedText != null && !directTransferLoadFailed;

  /// 成品行：去向分配子行(显示顺序)。
  List<DailyGridRow> allocationRows = [];

  /// Explicit receivers are user-owned; the remainder is derived as warehouse
  /// output and no new workshop receiver is suggested automatically.
  bool allocationManual = false;

  /// 成品行：工人亲手从某条去向上改掉的上层工单，重排不再自动建议给它；换来源即清空。
  final Set<String> allocationDeclined = {};

  /// 成品行：每个可送上层工单本行最多还能分多少(基本单位，已扣本张报工其它行)；
  /// 下拉「还差 N」与「已分满」读它，由重排算出。
  Map<String, double> directTransferRoomBase = const {};

  /// 成品行：每次重排后加一，去向格据此刷新(摘要、下拉条目)。
  final ValueNotifier<int> allocationRevision = ValueNotifier<int>(0);

  /// 去向分配子行所属的成品行；非空 = 本行是去向分配子行。
  DailyGridRow? allocationParent;
  bool get isAllocationRow => allocationParent != null;

  /// 去向分配子行：投给哪条上层工单的物料需求；null = 送入仓库。
  final ValueNotifier<String?> allocationDemandNotifier =
      ValueNotifier<String?>(null);
  String? get allocationDemandId => allocationDemandNotifier.value;
  set allocationDemandId(String? value) =>
      allocationDemandNotifier.value = value;

  /// 去向分配子行：分到的数量(报工单位)。
  final TextEditingController allocationQty = TextEditingController();

  /// 去向分配子行：工人亲手定过(或排在他改过的那条之上)，重排不再替换它。
  bool allocationFixed = false;

  /// 去向分配子行(固定)：工人自己要的数量(不含顺带接下的余量)；产量变小时显示值被压低，
  /// 压到 0 就先藏起来，这个数不丢，产量回升时按它恢复。
  double? allocationRequested;
  String? allocationRequestedExact;
  String? directTransferPrecisionIssue;
  Map<String, String> directTransferRoomBaseExact = const {};

  /// 去向分配子行：正在输入数量(输入框有焦点)，重排不改它的文字。
  bool allocationEditing = false;

  /// 去向分配子行：系统给出的建议(黄框)；工人改动即清除。
  final ValueNotifier<bool> allocationAutofilled = ValueNotifier<bool>(false);

  /// 去向分配子行：问题(红框 + 提交时列出)；null = 没问题。
  final ValueNotifier<String?> allocationIssue = ValueNotifier<String?>(null);

  /// 本次实际用料由完工申报量按单耗自动算出(物料子行)。
  ValueNotifier<bool> get materialUsageAutofilled => _materialInput.autofilled;

  /// 自动算出的文本；当前文本与它不同即视为用户改过。
  String? get materialAutofillText => _materialInput.autofillText;
  set materialAutofillText(String? value) =>
      _materialInput.autofillText = value;

  /// 保留旧比例字段用于兼容；手工实际用料不随产量变化覆盖。
  double? get materialManualRatio => _materialInput.manualRatio;
  set materialManualRatio(double? value) => _materialInput.manualRatio = value;

  /// 物料子行(挂在成品行下、不是去向分配也不是分组头的子行)。
  bool get isMaterialRow => depth > 0 && !isAllocationRow && !isGroupHeaderRow;

  /// 物料所属工单的可读标识(子计划号，取不到时退回 UUID 前 8 位)。
  String get materialSegmentLabel {
    final code = material?.executionSegmentCode;
    if (code != null && code.trim().isNotEmpty) return code.trim();
    final id = material?.executionSegmentId;
    return id == null || id.length < 8 ? '原领料工单' : id.substring(0, 8);
  }

  /// 可填的物料子行(自己负责提交且有权限)：必填红框与提交校验都只认这些行。
  bool get materialEditable =>
      isMaterialRow &&
      material != null &&
      materialOwnsInput &&
      !materialReadOnly;

  /// 本次可登记上限：待仓库收料的数量已被扣掉，填超会被服务端守卫直接拒绝。
  double get materialCap => material?.availableToSettleQty ?? 0;
  String? get materialCapText => material?.availableToSettleQtyText;

  double? get materialUsedValue => double.tryParse(materialUsed.text.trim());

  bool get materialInvalid {
    if (!materialEditable) return false;
    final value = productionExactQuantityUnits(
      materialUsed.text.trim().replaceFirst(RegExp(r'\.$'), ''),
    );
    final cap = productionExactQuantityUnits(materialCapText);
    return value == null ||
        value > productionQuantityMaxUnits ||
        cap == null ||
        value > cap;
  }

  bool get hasLinkedSource => planItemId != null && planItemId!.isNotEmpty;
  bool get hasSourceSnapshot => planNo.text.trim().isNotEmpty;
  bool get isFqcRecovery => fqcRecoveryAuthorizationId?.isNotEmpty == true;
  String? get recoveryLabel {
    if (!isFqcRecovery) return null;
    return switch (fqcRecoveryDispositionCode) {
      'REWORK' => '返工再检',
      'SCRAP' => '报废补产',
      'REJECT' => '拒收补产',
      _ => 'FQC恢复',
    };
  }

  /// 深拷贝（明细复制/粘贴用）：整行拷贝，含来源子任务引用与可报上限——日报保存
  /// 强制每行有精确来源，且按来源聚合校验「累计申报 ≤ 可报量」，拷引用不会放大申报。
  /// 仅 isFinal 重置：粘贴行是新一次申报，不继承上一行的「完结」标记
  /// （FQC 恢复行本就禁止完结，重置后口径一致）。
  /// 物料子行与去向分配子行不参与复制粘贴：它们由成品行派生，复制出来的第二份会把
  /// 同一份额度当成两份填。页面已用 canSelectRow 挡住勾选，这里再兜一次底。
  /// 去向分配不随行复制：粘贴行是新一次申报，由重排按当前余量重新给出建议。
  DailyGridRow clone() {
    if (isSubRow) {
      throw UnsupportedError('子行由成品行派生，不支持复制');
    }
    final c = DailyGridRow()
      ..planItemId = planItemId
      ..planId = planId
      ..executionSegmentId = executionSegmentId
      ..executionSegmentSalesAllocationId = executionSegmentSalesAllocationId
      ..executionSegmentCode = executionSegmentCode
      ..executionSegmentVersion = executionSegmentVersion
      ..fqcRecoveryAuthorizationId = fqcRecoveryAuthorizationId
      ..fqcRecoveryDispositionCode = fqcRecoveryDispositionCode
      ..fqcSourceReportNo = fqcSourceReportNo
      ..salesOrderItemId = salesOrderItemId
      ..salesOrderNo = salesOrderNo
      ..clientName = clientName
      ..unitRate = unitRate
      ..unitRateExact = unitRateExact
      ..qtyNeedsVerification = qtyNeedsVerification
      ..defectQtyNeedsVerification = defectQtyNeedsVerification
      ..orderQty = orderQty
      ..maxReportQty = maxReportQty
      ..maxReportQtyExact = maxReportQtyExact
      ..allowActualOverproduction = allowActualOverproduction
      ..supplementRequestId = null
      ..supplementProofId = null
      ..supplementApprovedActualQty = null
      ..remainingPlanQty = remainingPlanQty
      ..remainingPlanQtyExact = remainingPlanQtyExact
      ..remainingActualSurplusQty = remainingActualSurplusQty
      ..remainingActualSurplusQtyExact = remainingActualSurplusQtyExact
      ..pendingSupplementQty = pendingSupplementQty
      ..pendingSupplementQtyExact = pendingSupplementQtyExact
      ..directTransferCandidates = List.of(directTransferCandidates)
      ..directTransferBlockedTargets = List.of(directTransferBlockedTargets)
      ..directTransferReceiverLimit = directTransferReceiverLimit
      ..directTransferBlockedText = directTransferBlockedText
      ..directTransferLoadFailed = directTransferLoadFailed
      ..legacyManual = legacyManual
      ..goods = goods
      ..colorId = colorId
      ..unitId = unitId
      ..isFinal = false;
    c.qty.text = hasFixedSupplement ? '' : qty.text;
    // 固定追加批次的复制行不带来源，不良数也无处可记。
    c.defectQty.text = hasFixedSupplement ? '' : defectQty.text;
    c.weight.text = weight.text;
    c.planNo.text = planNo.text;
    c.remark.text = remark.text;
    c.overLimitReason.text = hasFixedSupplement ? '' : overLimitReason.text;
    if (hasFixedSupplement) {
      c
        ..planId = null
        ..planItemId = null
        ..executionSegmentId = null
        ..executionSegmentSalesAllocationId = null
        ..executionSegmentCode = null
        ..executionSegmentVersion = null
        ..salesOrderItemId = null
        ..salesOrderNo = null
        ..maxReportQty = null
        ..maxReportQtyExact = null
        ..remainingPlanQty = null
        ..remainingPlanQtyExact = null
        ..allowActualOverproduction = false
        ..planNo.clear();
    }
    return c;
  }

  /// 颜色（选货品后自动回填；单元格只读显示）；单位回填后作数量输入框后缀。
  final colorIdNotifier = ValueNotifier<String?>(null);
  String? get colorId => colorIdNotifier.value;
  set colorId(String? v) => colorIdNotifier.value = v;
  final unitIdNotifier = ValueNotifier<String?>(null);
  String? get unitId => unitIdNotifier.value;
  set unitId(String? v) => unitIdNotifier.value = v;

  /// 本批普通完工申报终结标记；不代表品质合格，FQC 后再按真实结果处理。
  final finalNotifier = ValueNotifier<bool>(false);
  bool get isFinal => finalNotifier.value;
  set isFinal(bool v) => finalNotifier.value = v;

  /// 防重复释放：行对象同时被表格（removeRows/replaceAll 删行即 dispose）与
  /// 页面（_applyMaterialRows 帧尾孤儿处置）两处管理，换稿/删行重排同帧内可能
  /// 先后走到 dispose——幂等一次为准，第二次静默跳过。
  bool _disposed = false;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    goodsNotifier.dispose();
    colorIdNotifier.dispose();
    unitIdNotifier.dispose();
    finalNotifier.dispose();
    qty.dispose();
    overLimitReason.dispose();
    defectQty.dispose();
    weight.dispose();
    planNo.dispose();
    remark.dispose();
    if (_ownsMaterialInput) _materialInput.dispose();
    allocationRevision.dispose();
    allocationDemandNotifier.dispose();
    allocationQty.dispose();
    allocationAutofilled.dispose();
    allocationIssue.dispose();
    super.dispose();
  }
}

/// 按已存的去向(草稿、已存日报、追加申请快照，形如提交体的
/// `{directTransferDemandId, qty}`)还原成本行的固定去向子行；候选读到后由重排校验、补齐。
void restoreOutputAllocations(
  DailyGridRow product,
  Iterable<Map<String, dynamic>> entries,
) {
  final rows = <DailyGridRow>[];
  for (final entry in entries) {
    final qtyText = productionExactQuantityText(
      entry['qtyExact'] ?? entry['qty'],
    );
    if (qtyText == null) throw const FormatException('去向数量缺少精确原文，请重新读取');
    final qty = double.parse(qtyText);
    if (qty <= 0) continue;
    final row = DailyGridRow()
      ..depth = 1
      ..allocationParent = product
      ..allocationDemandId = entry['directTransferDemandId'] as String?
      ..allocationFixed = true
      ..allocationRequested = qty
      ..allocationRequestedExact = qtyText;
    row.allocationQty.text = qtyText;
    rows.add(row);
  }
  product.allocationRows = rows;
  product.allocationManual = true;
}

/// 去向分配子行只在「有得选」时显示：有可送的上层工单，或已有转给上层工单的条目、或不止一条；
/// 只有一条「送入仓库」时由成品行的摘要或红字说明，不另占一行(顶层产品、委外件等不添噪音)。
bool showsOutputAllocations(DailyGridRow product) {
  final visible = product.allocationRows.where(outputAllocationVisible);
  return product.directTransferCandidates.isNotEmpty ||
      visible.length > 1 ||
      visible.any((row) => row.allocationDemandId != null);
}

/// Only a successful candidate read can establish the inline warehouse view.
/// Keep every saved receiver (including temporarily hidden fixed quantities)
/// and actionable allocation error in the details so the user can resolve it.
/// This changes presentation only; allocation rows remain owned by the page.
bool showsWarehouseOnlyDestination(DailyGridRow product) =>
    product.directTransferUnavailable &&
    product.directTransferCandidates.isEmpty &&
    !showsOutputAllocations(product) &&
    product.directTransferPrecisionIssue == null &&
    !product.allocationRows.any(
      (row) =>
          row.allocationDemandId != null ||
          (outputAllocationVisible(row) && row.allocationIssue.value != null),
    );

/// 这条去向要不要显示：工人定过、但被变小的完工申报量压到 0 的条目先藏起来(不提交、不报问题)，
/// 产量回升时按工人原来要的数回来；正在输入的那条即使是 0 也照常显示。
bool outputAllocationVisible(DailyGridRow allocation) =>
    allocation.allocationEditing ||
    (double.tryParse(allocation.allocationQty.text.trim()) ?? 0) > 0;

/// 提交体里本行的去向分配；全部送入仓库时返回 null(不传即整行送入仓库)。
List<Map<String, dynamic>>? outputAllocationBody(DailyGridRow product) {
  final body = <Map<String, dynamic>>[
    for (final allocation in product.allocationRows)
      if ((double.tryParse(allocation.allocationQty.text.trim()) ?? 0) > 0)
        {
          'directTransferDemandId': allocation.allocationDemandId,
          'qty': productionQuantityWire(allocation.allocationQty.text.trim()),
        },
  ];
  return body.any((entry) => entry['directTransferDemandId'] != null)
      ? body
      : null;
}

/// Give the first submitted output slice the single input for each demand.
void synchronizeMaterialInputOwners(
  Iterable<DailyGridRow> rows,
  Set<DailyGridRow> submitted,
) {
  final assigned = <String>{};
  for (final row in rows) {
    if (!row.isMaterialRow || row.material == null) continue;
    row.materialOwnsInput =
        !row.materialReadOnly &&
        submitted.contains(row.materialParent) &&
        assigned.add(row.material!.demandId);
  }
}

double materialReportedQuantity(
  String demandId,
  Iterable<DailyGridRow> rows,
  Set<DailyGridRow> submitted,
) =>
    double.tryParse(
      materialReportedQuantityText(demandId, rows, submitted) ?? '',
    ) ??
    0;

String? materialReportedQuantityText(
  String demandId,
  Iterable<DailyGridRow> rows,
  Set<DailyGridRow> submitted,
) {
  final parents = <DailyGridRow>{
    for (final row in rows)
      if (row.material?.demandId == demandId &&
          submitted.contains(row.materialParent))
        row.materialParent!,
  };
  var total = BigInt.zero;
  for (final parent in parents) {
    final raw = parent.qty.text.trim().replaceFirst(RegExp(r'\.$'), '');
    if (raw.isEmpty) continue;
    final qty = productionExactQuantityUnits(raw);
    if (qty == null) return null;
    total += qty;
  }
  return productionQuantityTextFromUnits(total);
}

/// A delivery's material cap does not mark the end of the production task.
bool completesProductionTask(DailyGridRow row, Iterable<DailyGridRow> rows) {
  if (row.isSubRow || row.isFqcRecovery) return false;
  final remaining = row.remainingPlanQty;
  final segment = row.executionSegmentId;
  if (segment == null) return false;
  var total = 0.0;
  for (final candidate in rows) {
    if (candidate.isSubRow ||
        candidate.isFqcRecovery ||
        candidate.executionSegmentId != segment) {
      continue;
    }
    if (candidate.isFinal) return true;
    final qty = double.tryParse(candidate.qty.text.trim());
    if (qty != null && qty.isFinite && qty > 0) total += qty;
  }
  return remaining != null && remaining > 0 && total >= remaining - 0.000001;
}

/// 不良数的唯一校验口径(格内红框与保存校验共用)：空 = 0 不校验；不小于 0、
/// 最多 4 位小数；大于 0 时本行必须已选报工工单且完工申报量大于 0。
String? productionReportDefectIssue(DailyGridRow row) {
  final raw = row.defectQty.text.trim();
  if (raw.isEmpty) return null;
  final value = productionExactQuantityUnits(raw);
  if (value == null) {
    return '不良数请填写不小于 0、最多 4 位小数的数量';
  }
  if (value > productionQuantityMaxUnits) return '不良数超过系统计量范围，请核对原输入';
  if (value <= BigInt.zero) return null;
  if (row.executionSegmentId == null) return '不良数只能记在已选择报工工单的行上';
  final qty = productionExactQuantityUnits(row.qty.text);
  if (qty == null || qty <= BigInt.zero) {
    return '先填写大于 0 的完工申报量，才能记录不良数';
  }
  return null;
}

/// 随行提交的不良数；空或 0 返回 null(不提交)。先经 [productionReportDefectIssue] 校验。
Object? productionReportDefectQty(DailyGridRow row) {
  final raw = row.defectQty.text.trim().replaceFirst(RegExp(r'\.$'), '');
  final units = productionExactQuantityUnits(raw);
  return units != null && units > BigInt.zero
      ? productionQuantityWire(raw)
      : null;
}

/// Keep stored draft use when a transient read failure hides its editor.
/// Only a successfully resolved change of output sources can remove old use.
List<Map<String, dynamic>> mergeDraftMaterialUsages({
  required Iterable<ProductionDailyReportMaterialUsage> saved,
  required Iterable<Map<String, dynamic>> edited,
  Set<String>? allowedSourceSegmentIds,
}) {
  final quantities = <String, Object>{
    for (final usage in saved)
      if (allowedSourceSegmentIds == null ||
          usage.materialExecutionSegmentId == null ||
          allowedSourceSegmentIds.contains(usage.materialExecutionSegmentId))
        usage.demandId: usage.qtyBaseText ?? usage.qtyBase,
  };
  for (final line in edited) {
    quantities[line['demandId'] as String] = productionQuantityWire(
      line['qtyBase'],
    );
  }
  return [
    for (final entry in quantities.entries)
      {'demandId': entry.key, 'qtyBase': productionQuantityWire(entry.value)},
  ];
}

/// Only a proven linear requirement can provide a proportional suggestion.
double? materialUsagePerProduct(ProductionMaterialClearanceRow material) {
  if (material.requirementMode != 'LINEAR') return null;
  final forProduct = material.requiredForProductQty;
  if (forProduct != null && forProduct > 0 && material.requiredQty > 0) {
    return material.requiredQty / forProduct;
  }
  final perProduct = material.perProductQty;
  if (perProduct != null && perProduct > 0) return perProduct;
  return null;
}

/// 按完工申报量自动算本次实际用料(V595)：完工量 × 单耗(或用户手改后的比例)，
/// 封顶到「本次可登记」上限，四位小数。算不出(无单耗/完工量无效)返回 null。
double? expectedMaterialUsage({
  required double reportedQty,
  required ProductionMaterialClearanceRow material,
  double? ratioOverride,
}) {
  final text = expectedMaterialUsageText(
    reportedQty: reportedQty,
    material: material,
    ratioOverride: ratioOverride,
  );
  return text == null ? null : double.parse(text);
}

String? expectedMaterialUsageText({
  required Object? reportedQty,
  required ProductionMaterialClearanceRow material,
  double? ratioOverride,
}) {
  final qty = productionExactQuantityUnits(reportedQty);
  final cap = productionExactQuantityUnits(material.availableToSettleQtyText);
  if (qty == null || qty <= BigInt.zero || cap == null) return null;
  // Exact package/batch quantities cannot be prorated, even from a prior edit.
  if (material.requirementMode != 'LINEAR') return null;
  final forProduct = productionExactQuantityUnits(
    material.requiredForProductQtyText,
  );
  final required = productionExactQuantityUnits(material.requiredQtyText);
  BigInt numerator, denominator;
  if (ratioOverride != null) {
    final ratio = productionExactQuantityUnits(ratioOverride, scale: 6);
    if (ratio == null) return null;
    numerator = qty * ratio;
    denominator = BigInt.from(1000000);
  } else if (forProduct != null &&
      forProduct > BigInt.zero &&
      required != null &&
      required > BigInt.zero) {
    numerator = qty * required;
    denominator = forProduct;
  } else {
    final ratio = productionExactQuantityUnits(
      material.perProductQtyText,
      scale: 6,
    );
    if (ratio == null || ratio <= BigInt.zero) return null;
    numerator = qty * ratio;
    denominator = BigInt.from(1000000);
  }
  final rounded =
      (numerator * BigInt.two + denominator) ~/ (denominator * BigInt.two);
  return productionQuantityTextFromUnits(rounded > cap ? cap : rounded);
}

/// 生产日报明细列：货品(点选) / 颜色(只读) / 完工申报量 / 不良数 / 实际重量 /
/// 关联计划号 / 备注。[onPickGoods] 由编辑页提供；[colorEntries]/[unitEntries] 由编辑页注入
/// （颜色只读显示 + 数量输入框单位后缀，2026-10-10 数量内联口径）。
/// [hasSubRows]/[isLastSubRow] 由编辑页按当前行序计算：本表把成品行与
/// 它的子行扁平混排，树形缩进和连接线要知道「这行下面还有没有子行」「这是不是
/// 最后一个子行」。[onMaterialChanged] 让编辑页在实耗输入变化时重算必填红框与提交态。
/// [isGroupExpanded]/[onToggleGroup] 是「产出去向」「子件用料」两个分组的展开态
/// 与切换回调（2026-10-10 双分组口径）：分组头行的展开钮与成品行去向格收起态的
/// 悬停全文都读它；去向分组新建默认展开、编辑默认收起，用料分组默认展开。
/// [productOrdinalOf] 给出成品行在当前渲染序里的序号，驱动子树连线与箭头圆底
/// 按产品奇偶两色轮换（与物料分析「按产品看」同一视觉语言，2026-10-10 口径）。
List<EditableGridColumn<DailyGridRow>> dailyGridColumns({
  required BuildContext context,
  required Future<void> Function(DailyGridRow row) onPickGoods,
  required Future<void> Function(DailyGridRow row) onPickSource,
  required void Function(DailyGridRow row) onClearSource,
  Future<void> Function(DailyGridRow row)? onOpenSource,
  required Map<String, String> colorEntries,
  required Map<String, String> unitEntries,
  bool standaloneDetails = false,
  bool Function(DailyGridRow row)? hasSubRows,
  bool Function(DailyGridRow row)? isLastSubRow,
  void Function()? onMaterialChanged,
  void Function(DailyGridRow allocation, String? demandId)?
  onAllocationDestinationChanged,
  void Function(DailyGridRow allocation)? onAllocationQtyChanged,
  void Function(DailyGridRow allocation, bool focused)? onAllocationQtyFocus,
  bool Function(DailyGridRow product, DailyRowGroup group)? isGroupExpanded,
  void Function(DailyGridRow product, DailyRowGroup group)? onToggleGroup,
  int Function(DailyGridRow product)? productOrdinalOf,
}) {
  // 列说明统一挂表头 ⓘ（2026-09-09 口径）：每行重复的 ⓘ 既冗余又挤占格宽。
  final l10n = workflowFieldText(context);
  return [
    EditableGridColumn<DailyGridRow>(
      key: 'goods',
      label: standaloneDetails ? '货品名称' : '货品名称 / 用料',
      // 子行树形缩进(2×24)+ 叶子位(48)：树单元的缩进与图标位不进 textOf 的
      // 自动量宽，宽度只能硬给，否则物料名一律被挤成省略号（缩进按物料分析
      // 「按产品看」同款 24，双分组后子行深一层，320→368）。
      width: standaloneDetails
          ? 280
          : 272 +
                UtenTreeTableCell.prefixWidthOf(context, depth: 2, indent: 24),
      required: true,
      // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色**各占一列**。
      // 报工行多由来源子任务冻结带入，同名不同色/不同编号的货品只看名称会报到
      // 别的货上；这里只放名称，编号见下一列，颜色/单位本表本来就有独立列。
      textOf: (r) => r.isGroupHeaderRow
          ? (r.groupHeader == DailyRowGroup.allocations ? '产出去向' : '子件用料')
          : r.isAllocationRow
          ? '去向'
          : r.isMaterialRow
          ? (r.material?.goodsName ?? '')
          : (r.goods?.name ?? ''),
      listenableOf: (r) => r.goodsNotifier,
      // 格尾树形/选择图标计入量宽（2026-09-16）；子行的树缩进仍由基础宽兜。
      chromeWidth: UtenEditableGridCellSpec.dropdownChevronWidth,
      cellBuilder: (context, row) {
        // 子树连线/箭头圆底按成品行奇偶两色轮换（与物料分析「按产品看」同款，
        // 2026-10-10 用户口径「参考按产品视图」）：同一成品行的分组头与子行
        // 整棵子树同色、相邻成品行换色；未接回调的宿主维持默认灰。
        DailyGridRow? subtreeProduct;
        if (row.isGroupHeaderRow) {
          subtreeProduct = row.groupParent;
        } else if (row.isAllocationRow) {
          subtreeProduct = row.allocationParent;
        } else if (row.isMaterialRow) {
          subtreeProduct = row.materialParent;
        }
        final ordinal = subtreeProduct == null || productOrdinalOf == null
            ? null
            : productOrdinalOf(subtreeProduct);
        final dark = Theme.of(context).brightness == Brightness.dark;
        final Color? guideColor = ordinal == null || ordinal < 0
            ? null
            : ordinal.isEven
            ? (dark
                  ? UtenColors.bomProductGuideEvenDark
                  : UtenColors.bomProductGuideEven)
            : (dark
                  ? UtenColors.bomProductGuideOddDark
                  : UtenColors.bomProductGuideOdd);
        // 箭头圆底明暗两主题同用深档（箭头自动反白），与物料分析同路数。
        final Color? toggleColor = ordinal == null || ordinal < 0
            ? null
            : ordinal.isEven
            ? UtenColors.bomProductGuideEven
            : UtenColors.bomProductGuideOdd;
        if (row.isGroupHeaderRow) {
          final group = row.groupHeader!;
          final product = row.groupParent;
          final toggle = onToggleGroup;
          // 未接回调（如纯单元格预览）不给可点的钮，避免死按钮。
          final expanded = product == null || toggle == null
              ? true
              : isGroupExpanded?.call(product, group) ?? true;
          return UtenTreeTableCell(
            depth: 1,
            sequence: '',
            sequenceInline: true,
            showLeafMarker: false,
            guideBleed: UtenEditableGrid.cellVerticalPadding,
            isLastChild: isLastSubRow?.call(row) ?? true,
            indent: 24,
            guideColor: guideColor,
            toggleColor: toggleColor,
            title: group == DailyRowGroup.allocations ? '产出去向' : '子件用料',
            hasChildren: toggle != null && product != null,
            expanded: expanded,
            onToggle: toggle == null || product == null
                ? null
                : () => toggle(product, group),
            toggleKey: ValueKey(
              'daily-group-toggle-${product?.localRowId}-$group',
            ),
            toggleTooltip: group == DailyRowGroup.allocations
                ? (expanded ? '收起产出去向' : '展开产出去向')
                : (expanded ? '收起子件用料' : '展开子件用料'),
            childCount: row.groupChildCount,
          );
        }
        if (row.isAllocationRow) {
          return UtenTreeTableCell(
            depth: 2,
            sequence: '',
            sequenceInline: true,
            showLeafMarker: false,
            guideBleed: UtenEditableGrid.cellVerticalPadding,
            isLastChild: isLastSubRow?.call(row) ?? true,
            indent: 24,
            guideColor: guideColor,
            mutedToggleWhenChildless: true,
            // 分组头已写「产出去向」：每条子行只标自己是「去向」。
            title: '去向',
          );
        }
        if (row.isMaterialRow) {
          return UtenTreeTableCell(
            depth: 2,
            sequence: '',
            sequenceInline: true,
            showLeafMarker: false,
            // 连接线要跨过宿主数据格的纵向内边距才连成一条而不是虚线；
            // 数值取自表格组件公开的常量，不在调用点抄魔数（2026-09-15）。
            guideBleed: UtenEditableGrid.cellVerticalPadding,
            isLastChild: isLastSubRow?.call(row) ?? true,
            indent: 24,
            guideColor: guideColor,
            mutedToggleWhenChildless: true,
            title: row.material?.goodsName ?? '未命名物料',
            // 2026-09-27 用户口径：非共享物料的「本工单领用」小字删除；
            // 共享物料保留「沿用前批已领 · 工单号」（有区分价值）。
            subtitle: row.materialShared
                ? '沿用前批已领 · ${row.materialSegmentLabel}'
                : null,
          );
        }
        return RequiredCellFrame(
          listenable: row.goodsNotifier,
          isEmpty: () => row.goods == null,
          child: InkWell(
            onTap: row.hasLinkedSource ? null : () => onPickGoods(row),
            child: InputDecorator(
              // 选择格统一内边距（2026-10-06 表格控件统一口径）。
              decoration: InputDecoration(
                isDense: true,
                contentPadding: UtenEditableGridCellSpec.contentPaddingOf(
                  context,
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: ValueListenableBuilder<GoodsOption?>(
                      valueListenable: row.goodsNotifier,
                      builder: (context, g, _) => g == null
                          ? Text(
                              utenFieldPlaceholder(label: '货品名称')!,
                              style: Theme.of(
                                context,
                              ).inputDecorationTheme.hintStyle,
                            )
                          : UtenGoodsIdentityCell(name: g.name),
                    ),
                  ),
                  if (hasSubRows?.call(row) ?? false)
                    Padding(
                      padding: const EdgeInsets.only(right: UtenSpacing.s4),
                      child: Icon(
                        Icons.account_tree_outlined,
                        size: 14,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  const Icon(Icons.search_rounded, size: 16),
                ],
              ),
            ),
          ),
        );
      },
    ),
    EditableGridColumn<DailyGridRow>(
      key: 'goodsCode',
      label: '编号',
      width: 130,
      textOf: (r) => r.isGroupHeaderRow
          ? ''
          : r.isAllocationRow
          ? ''
          : r.isMaterialRow
          ? (r.material?.goodsCode ?? '')
          : (r.goods?.code ?? ''),
      listenableOf: (r) => r.goodsNotifier,
      cellBuilder: (context, row) => row.isGroupHeaderRow || row.isAllocationRow
          ? const SizedBox.shrink()
          : row.isMaterialRow
          ? UtenGoodsAttributeCell(row.material?.goodsCode)
          : ValueListenableBuilder<GoodsOption?>(
              valueListenable: row.goodsNotifier,
              builder: (context, goods, _) =>
                  UtenGoodsAttributeCell(goods?.code),
            ),
    ),
    EditableGridColumn<DailyGridRow>(
      key: 'color',
      label: '颜色',
      width: 130,
      textOf: (r) => r.isGroupHeaderRow
          ? ''
          : r.isAllocationRow
          ? ''
          : r.isMaterialRow
          ? (r.material?.colorName ?? '')
          : (colorEntries[r.colorId ?? ''] ?? ''),
      listenableOf: (r) => r.colorIdNotifier,
      cellBuilder: (context, row) => row.isGroupHeaderRow || row.isAllocationRow
          ? const SizedBox.shrink()
          : row.isMaterialRow
          ? UtenGoodsAttributeCell(row.material?.colorName)
          : _readOnlyMasterCell(context, row.colorIdNotifier, colorEntries),
    ),
    // 2026-10-10 用户口径（全站表格数量口径）：独立「单位」列撤销，单位跟在
    // 完工申报量/不良数等数量输入框后缀；物料子行读材料主档单位，去向子行
    // 与所属成品行同单位。
    EditableGridColumn<DailyGridRow>(
      key: 'qty',
      exactValueOf: (r) => r.isSubRow ? null : r.qty.text,
      exactListenableOf: (r) => r.qty,
      label: '完工申报量',
      width: 152,
      numeric: true,
      required: true,
      headerInfo: l10n.workflowReportQuantityHint,
      cellBuilder: (context, row) => row.isSubRow
          ? const SizedBox.shrink()
          : RequiredCellFrame(
              listenable: row.qty,
              isEmpty: () => (double.tryParse(row.qty.text.trim()) ?? 0) <= 0,
              child: ValueListenableBuilder<String?>(
                valueListenable: row.unitIdNotifier,
                builder: (context, unitId, _) => TextField(
                  controller: row.qty,
                  onChanged: (_) => row.qtyNeedsVerification = false,
                  readOnly: row.hasFixedSupplement,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: UtenInputDecoration(
                    InputDecoration(
                      isDense: true,
                      hintText: '完工申报量',
                      hintStyle: Theme.of(
                        context,
                      ).inputDecorationTheme.hintStyle,
                      suffixText: _unitSuffixText(unitId, unitEntries),
                    ),
                  ),
                ),
              ),
            ),
    ),
    EditableGridColumn<DailyGridRow>(
      key: 'overLimitReason',
      label: '超限原因',
      width: 220,
      headerInfo: '实际产量超过当前有效额度时填写原因。额度内产出继续原流程，超限部分由计划处理；不会自动增加需求或可用库存。',
      textOf: (row) => row.isSubRow ? '' : row.overLimitReason.text,
      listenableOf: (row) => row.overLimitReason,
      cellBuilder: (context, row) => row.isSubRow
          ? const SizedBox.shrink()
          : ListenableBuilder(
              listenable: Listenable.merge([row.qty, row.goodsNotifier]),
              builder: (context, _) {
                if (!row.canRecordOverLimit) return const SizedBox.shrink();
                final over = row.estimatedOverLimitQtyText;
                return TextField(
                  key: ValueKey('over-limit-reason-${row.localRowId}'),
                  controller: row.overLimitReason,
                  maxLength: 500,
                  decoration: UtenInputDecoration(
                    InputDecoration(
                      isDense: true,
                      counterText: '',
                      hintText: '超限原因（超量时必填）',
                      hintStyle: Theme.of(
                        context,
                      ).inputDecorationTheme.hintStyle,
                    ),
                    info:
                        (productionExactQuantityUnits(over) ?? BigInt.zero) >
                            BigInt.zero
                        ? '超限 $over，请填写 2–500 字原因'
                        : null,
                  ),
                );
              },
            ),
    ),
    // ADR-129 不良数：可选，只在已选报工工单的行上填；空 = 0。
    EditableGridColumn<DailyGridRow>(
      key: 'defectQty',
      exactValueOf: (r) => r.isSubRow ? null : r.defectQty.text,
      exactListenableOf: (r) => r.defectQty,
      label: '不良数',
      width: 138,
      numeric: true,
      headerInfo: productionDailyReportDefectInfo,
      textOf: (r) => r.isMaterialRow ? '' : r.defectQty.text,
      listenableOf: (r) => r.defectQty,
      cellBuilder: (context, row) {
        if (row.isMaterialRow) return const SizedBox.shrink();
        // 来源随选择/清除来源一起变，货品通知器在来源字段之后赋值，借它重建本格。
        return ValueListenableBuilder<GoodsOption?>(
          valueListenable: row.goodsNotifier,
          builder: (context, _, _) => row.executionSegmentId == null
              ? Text(
                  '—',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                )
              : RequiredCellFrame(
                  listenable: Listenable.merge([row.defectQty, row.qty]),
                  isEmpty: () => productionReportDefectIssue(row) != null,
                  child: ValueListenableBuilder<String?>(
                    valueListenable: row.unitIdNotifier,
                    builder: (context, unitId, _) => TextField(
                      controller: row.defectQty,
                      onChanged: (_) => row.defectQtyNeedsVerification = false,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [productionQuantityInputFormatter],
                      decoration: UtenInputDecoration(
                        InputDecoration(
                          isDense: true,
                          hintText: '不良数',
                          hintStyle: Theme.of(
                            context,
                          ).inputDecorationTheme.hintStyle,
                          suffixText: _unitSuffixText(unitId, unitEntries),
                        ),
                      ),
                    ),
                  ),
                ),
        );
      },
    ),
    // ===== V583 物料子行专用两列：成品行留空 =====
    // 2026-09-27 用户口径：「产量分流」列退役——提示语与保存核定重复，
    // 不再单独占一列（产量的需求/公共份额由系统保存时核定）。
    EditableGridColumn<DailyGridRow>(
      key: 'issuedQty',
      exactValueOf: (r) =>
          r.isMaterialRow ? r.material?.issuedQty.toString() : null,
      label: '领料量',
      width: 138,
      numeric: true,
      headerInfo:
          '仓库已实际发给本工单的数量(基本单位)。它是只读事实，'
          '要改只能走仓库的出库红冲。',
      textOf: (r) => r.isMaterialRow
          ? formatQtyWithUnit(r.material?.issuedQty ?? 0, r.material?.unitName)
          : '',
      cellBuilder: (context, row) => row.isMaterialRow
          ? Text(
              formatQtyWithUnit(
                row.material?.issuedQty ?? 0,
                row.material?.unitName,
              ),
            )
          : const SizedBox.shrink(),
    ),
    EditableGridColumn<DailyGridRow>(
      key: 'materialUsed',
      exactValueOf: (r) => r.isMaterialRow ? r.materialUsed.text : null,
      exactListenableOf: (r) => r.materialUsed,
      label: '本次实际用料',
      width: 174,
      numeric: true,
      required: true,
      headerInfo:
          '填本次这张报工真正用掉的数量，允许填 0(这批料一点没用)。'
          '上限是「本次还能登记多少」——已提交待仓库收料的部分不能再记成消耗。'
          '保存保持填写值，余料由审核页核对并选择留用或申请退仓。',
      cellBuilder: (context, row) {
        if (!row.isMaterialRow) return const SizedBox.shrink();
        if (!row.materialOwnsInput) {
          // 同一工单已在上面某个成品行下登记过：这里只回显，不重复占额度。
          return Tooltip(
            message: '本工单的物料已在上面的成品行下登记，这里只作对照',
            child: Text(
              [
                row.materialUsed.text.trim().isEmpty
                    ? '待填写'
                    : row.materialUsed.text.trim(),
                if (row.material?.unitName?.trim().isNotEmpty == true)
                  row.material!.unitName!.trim(),
              ].join(' '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          );
        }
        return RequiredCellFrame(
          listenable: row.materialUsed,
          // 成品行的完工量是「必须大于 0」，物料实耗是「必须填、可以是 0」：
          // 逼车间为没用的料编个正数就是在造假账，所以这里判的是「空 / 负 / 超上限」。
          isEmpty: () => row.materialInvalid,
          child: ValueListenableBuilder<bool>(
            valueListenable: row.materialUsageAutofilled,
            builder: (context, autofilled, _) => TextField(
              key: ValueKey('daily-material-used-${row.material?.demandId}'),
              controller: row.materialUsed,
              enabled: !row.materialReadOnly,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) => onMaterialChanged?.call(),
              // 可登记上限走 UtenInputDecoration 的 info（格内统一披露），
              // 不能用裸 helperText——`uten_field_message_source_contract_test`
              // 会直接判红（全站口径：提示与错误都留在字段里，不另开一行）。
              // V595：由完工申报量自动算出的值套「预填黄框 + 警示图标」，
              // 提示文案走 UtenFieldMessage.autofill(与带记忆的框同款)，用户改动即清除。
              decoration: applyAutofillHint(
                UtenInputDecoration(
                  InputDecoration(
                    isDense: true,
                    hintText: '本次实际用料',
                    hintStyle: Theme.of(context).inputDecorationTheme.hintStyle,
                    // 物料子行单位取材料台账单位（行创建时已冻结，不随行内 notifier 变）。
                    suffixText: row.material?.unitName,
                    helper: autofilled
                        ? const UtenFieldMessage.autofill(
                            '已按完工申报量 × 单耗自动算出，请核对本次实际用料；'
                            '未修改的建议随产量更新，手工填写后保持原值',
                          )
                        : null,
                  ),
                  info: row.materialReadOnly
                      ? null
                      : row.materialCapText == null
                      ? '可登记用料量缺少精确原文，请重新读取材料台账核对；原输入已保留'
                      : row.material?.requirementMode == 'LINEAR'
                      ? '可登记 ${row.materialCapText}；实际工艺耗用含 BOM 已计入的正常损耗'
                      : '整包、固定批次或缺少计量依据不能按平均单耗估算。请填写实际工艺耗用（可填 0），可登记 ${row.materialCapText}',
                ),
                Theme.of(context),
                autofilled: autofilled && !row.materialReadOnly,
              ),
            ),
          ),
        );
      },
    ),
    // ===== V736/ADR-127 产出去向两列：成品行写摘要，无法流转的原因悬停显示，物料子行留空 =====
    EditableGridColumn<DailyGridRow>(
      key: 'destination',
      label: '产出去向',
      width: standaloneDetails ? 140 : 300,
      headerInfo:
          '实际产量分到哪里：「转下一道工序」= 班组自检合格后不入库，直接交给本车间的上层工单'
          '(父件)，审核时自动放行、入本车间内料仓并投入，不用再走领料。\n'
          '「送入仓库」= 交仓库送检、品质检验、点收入库。\n'
          '系统按先急后缓把本行产量逐个分给还缺料的上层工单(黄框为系统建议)，分不完的送入仓库；'
          '改任一条的去向或数量，下面会自动补一条接着分，直到分完。\n'
          '下拉里「已分满」表示本张报工其它行已把它分满；红字是不能收的原因(例如委外件要先送入仓库、'
          '上层工单在别的车间)。无法车间内流转时默认送入仓库，去向不可修改，悬停查看原因。'
          '计划内公共备货与超出计划的产量一律送入仓库。',
      textOf: (r) =>
          r.acceptedDestinationLabel ??
          (r.isGroupHeaderRow
              ? ''
              : r.isAllocationRow
              ? _allocationOptionText(r)
              : r.isMaterialRow
              ? ''
              : standaloneDetails
              ? _inlineProductDestinationText(r)
              : _productDestinationText(r)),
      listenableOf: (r) =>
          r.isAllocationRow ? r.allocationDemandNotifier : r.allocationRevision,
      chromeWidth: UtenEditableGridCellSpec.dropdownChevronWidth,
      cellBuilder: (context, row) {
        if (row.acceptedDestinationLabel case final accepted?) {
          // 已审核行只读回看：截断显示，全文放恒定悬停提示（兜底与正文同文案）。
          return Tooltip(
            message: accepted,
            child: Text(accepted, maxLines: 1, overflow: TextOverflow.ellipsis),
          );
        }
        if (row.isGroupHeaderRow || row.isMaterialRow) {
          return const SizedBox.shrink();
        }
        if (!row.isAllocationRow) {
          return ValueListenableBuilder<int>(
            valueListenable: row.allocationRevision,
            builder: (context, _, _) {
              final blocked = row.directTransferBlockedText;
              // 读取失败需要处理；确认不可转则显示实际去向，原因只在悬停时展示。
              final Widget text;
              if (row.directTransferLoadFailed && blocked != null) {
                text = DirectTransferBlockedText(blocked);
              } else {
                final summary = standaloneDetails
                    ? _inlineProductDestinationText(row)
                    : _productDestinationText(row);
                // Tooltip 恒定包裹 + 兜底文案：按内容条件切换包裹会拆掉子树重建，
                // 悬停/焦点态丢失（docs/02-组件库/WeightGridColumn.md 同口径）。
                // 收起态的去向子行不在表格里：悬停给逐条「去向全名：数量」全文，
                // 名称过长被单行省略的部分在这里看全；展开态给摘要即可。
                final expanded =
                    isGroupExpanded?.call(row, DailyRowGroup.allocations) ??
                    true;
                final fallback = summary.isEmpty ? '—' : summary;
                text = Tooltip(
                  message: blocked != null && blocked.isNotEmpty
                      ? blocked
                      : expanded && !standaloneDetails
                      ? fallback
                      : _collapsedDestinationDetail(row, fallback),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      summary.isEmpty ? '—' : summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                );
              }
              return text;
            },
          );
        }
        final parent = row.allocationParent!;
        return ValueListenableBuilder<int>(
          valueListenable: parent.allocationRevision,
          builder: (context, _, _) => ValueListenableBuilder<String?>(
            valueListenable: row.allocationIssue,
            builder: (context, issue, _) => ValueListenableBuilder<bool>(
              valueListenable: row.allocationAutofilled,
              builder: (context, autofilled, _) {
                // 服务端判定一个可送的上层工单都没有：只读显示送入仓库，悬停查看原因。
                if (parent.directTransferUnavailable &&
                    row.allocationDemandId == null) {
                  return Tooltip(
                    message: parent.directTransferBlockedText!,
                    child: const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('送入仓库', maxLines: 1),
                    ),
                  );
                }
                // 下拉收起态单行省略：恒定悬停给当前选中项全文（工单还差多少一目了然），
                // 有问题时在全文后补原因，完整名称始终可查；选不中任何项时兜底「送入仓库」。
                final selected = _allocationOptionText(row);
                return Tooltip(
                  message: [
                    selected.isEmpty ? '送入仓库' : selected,
                    if (issue != null && issue.isNotEmpty) issue,
                  ].join('\n'),
                  child: UtenDropdownField(
                    key: ValueKey(
                      'daily-allocation-destination-${identityHashCode(row)}',
                    ),
                    dense: true,
                    allowClear: false,
                    value:
                        row.allocationDemandId ??
                        outputAllocationWarehouseValue,
                    autofilled: autofilled && issue == null,
                    errorMessage: issue,
                    items: outputAllocationOptions(row),
                    onChanged: (value) {
                      if (value == null) return;
                      onAllocationDestinationChanged?.call(
                        row,
                        value == outputAllocationWarehouseValue ? null : value,
                      );
                    },
                  ),
                );
              },
            ),
          ),
        );
      },
    ),
    EditableGridColumn<DailyGridRow>(
      key: 'allocationQty',
      exactValueOf: (r) => r.isAllocationRow ? r.allocationQty.text : null,
      exactListenableOf: (r) => r.allocationQty,
      label: '去向数量',
      width: 154,
      numeric: true,
      headerInfo:
          '这一条去向分多少(与完工申报量同单位)。所有去向合计始终等于本行完工申报量：'
          '改大会压低下面的条目，改小则多出来的自动排到下面(先急后缓的下一个上层工单，没有就送入仓库)；'
          '改成 0 的条目会消失。转给上层工单的数量不能超过它还差的数量。',
      textOf: (r) => r.isAllocationRow ? r.allocationQty.text : '',
      listenableOf: (r) => r.allocationQty,
      cellBuilder: (context, row) {
        if (!row.isAllocationRow) return const SizedBox.shrink();
        // 与完工申报量同单位：取所属成品行回填的单位（换来源会整批重排去向子行，
        // 拿创建时的快照即可，不必随 unitIdNotifier 实时跟）。
        final unit = _unitSuffixText(row.allocationParent?.unitId, unitEntries);
        return ValueListenableBuilder<String?>(
          valueListenable: row.allocationIssue,
          builder: (context, issue, _) => ValueListenableBuilder<bool>(
            valueListenable: row.allocationAutofilled,
            builder: (context, autofilled, _) => Focus(
              onFocusChange: (focused) =>
                  onAllocationQtyFocus?.call(row, focused),
              child: TextField(
                key: ValueKey('daily-allocation-qty-${identityHashCode(row)}'),
                controller: row.allocationQty,
                readOnly:
                    row.allocationParent?.directTransferUnavailable ?? false,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => onAllocationQtyChanged?.call(row),
                decoration: applyAutofillHint(
                  UtenInputDecoration(
                    InputDecoration(
                      isDense: true,
                      hintText: '去向数量',
                      hintStyle: Theme.of(
                        context,
                      ).inputDecorationTheme.hintStyle,
                      suffixText: unit,
                      error: utenFieldError(issue),
                      helper: autofilled && issue == null
                          ? const UtenFieldMessage.autofill(
                              '系统按先急后缓给出的建议数量，请核对；改动后下面会自动重排',
                            )
                          : null,
                    ),
                  ),
                  Theme.of(context),
                  autofilled: autofilled && issue == null,
                ),
              ),
            ),
          ),
        );
      },
    ),
    // 2026-09-12 用户口径「新建生产日报不显示重量」：实际重量列撤出编辑表格
    //（行模型 weight 字段保留，回填/提交透传既有单不受影响；详情页只读回看不变）。
    EditableGridColumn<DailyGridRow>(
      key: 'planNo',
      label: '来源子任务',
      width: 240,
      textOf: (row) =>
          row.isSubRow ? '' : (row.executionSegmentCode ?? row.planNo.text),
      // 格尾跳转图标计入量宽（2026-09-16）。
      chromeWidth: UtenEditableGridCellSpec.dropdownChevronWidth,
      cellBuilder: (context, row) => row.isSubRow
          ? const SizedBox.shrink()
          : ValueListenableBuilder<TextEditingValue>(
              valueListenable: row.planNo,
              builder: (context, value, _) {
                final linked = row.hasLinkedSource;
                final canOpen =
                    linked &&
                    row.planId != null &&
                    row.executionSegmentId != null &&
                    onOpenSource != null;
                final label = row.executionSegmentCode ?? value.text;
                return Row(
                  children: [
                    Expanded(
                      child: Tooltip(
                        message:
                            [
                                  value.text,
                                  row.recoveryLabel,
                                  row.fqcSourceReportNo,
                                  row.salesOrderNo,
                                ]
                                .whereType<String>()
                                .where((v) => v.isNotEmpty)
                                .join(' · '),
                        child: TextButton.icon(
                          onPressed: canOpen
                              ? () => onOpenSource(row)
                              : linked
                              ? null
                              : () => onPickSource(row),
                          icon: Icon(
                            canOpen
                                ? Icons.open_in_new_rounded
                                : Icons.search_rounded,
                            size: 16,
                          ),
                          label: Text(
                            label.isEmpty ? '选择来源工单' : label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: label.isEmpty
                                ? Theme.of(
                                    context,
                                  ).inputDecorationTheme.hintStyle
                                : null,
                          ),
                        ),
                      ),
                    ),
                    if (linked || row.hasSourceSnapshot) ...[
                      IconButton(
                        tooltip: '重新选择来源子任务',
                        onPressed: () => onPickSource(row),
                        icon: const Icon(Icons.search_rounded, size: 16),
                      ),
                      IconButton(
                        tooltip: '清除来源',
                        onPressed: () => onClearSource(row),
                        icon: const Icon(Icons.close_rounded, size: 16),
                      ),
                    ],
                  ],
                );
              },
            ),
    ),
    EditableGridColumn<DailyGridRow>(
      key: 'remark',
      label: '备注',
      width: 180,
      textOf: (r) => r.isSubRow ? '' : r.remark.text,
      listenableOf: (r) => r.remark,
      cellBuilder: (context, row) => row.isSubRow
          ? const SizedBox.shrink()
          : TextField(
              controller: row.remark,
              decoration: const UtenInputDecoration(
                InputDecoration(isDense: true, labelText: '备注'),
              ),
            ),
    ),
  ];
}

/// 数量文本：整数不带小数点，小数最多 4 位且不留尾零(与全站数量显示同口径)。
String _quantityText(double value) => outputAllocationQuantityText(value);

/// 数量输入格的单位后缀（2026-10-10 数量内联口径）：完工申报量/不良数/去向数量
/// 的单位跟在输入框后缀，随 unitIdNotifier 换货品回填即时刷新；空单位无后缀。
String? _unitSuffixText(String? unitId, Map<String, String> unitEntries) {
  if (unitId == null || unitId.isEmpty) return null;
  final name = unitEntries[unitId];
  return (name == null || name.isEmpty) ? null : name;
}

/// 去向下拉里「送入仓库」那一项的值(下拉值不能为空，用它代表「不转给任何上层工单」)。
const outputAllocationWarehouseValue = '__WAREHOUSE__';

/// In a mixed table, receivers are edited in the product's details. The inline
/// column names the sole warehouse choice without repeating its quantity.
String _inlineProductDestinationText(DailyGridRow product) {
  if (showsWarehouseOnlyDestination(product)) return '送入仓库';
  if (showsOutputAllocations(product) ||
      product.directTransferLoadFailed ||
      product.directTransferPrecisionIssue != null ||
      product.allocationRows.any((row) => row.allocationDemandId != null)) {
    return '下方分配';
  }
  return '—';
}

/// 成品行正文与列宽测量共用实际去向；不可转原因只放悬停提示，读取失败仍直接报错。
String _productDestinationText(DailyGridRow product) {
  if (product.directTransferLoadFailed &&
      product.directTransferBlockedText != null) {
    return product.directTransferBlockedText!;
  }
  final summary = outputAllocationSummary(product);
  return summary.isEmpty && product.directTransferUnavailable
      ? '送入仓库'
      : summary;
}

/// 去向分组收起时「产出去向」格的悬停全文：逐条列「去向全名：数量」。去向名称
/// 过长时正文摘要只有合计数，单条的全名与数量在这里看全；没有可列的条目退回摘要。
String _collapsedDestinationDetail(DailyGridRow product, String fallback) {
  final lines = [
    for (final allocation in product.allocationRows.where(
      outputAllocationVisible,
    ))
      '${_allocationOptionText(allocation).trim().isEmpty ? '送入仓库' : _allocationOptionText(allocation)}'
          '：${allocation.allocationQty.text.trim().isEmpty ? '0' : allocation.allocationQty.text.trim()}',
  ];
  return lines.isEmpty ? fallback : lines.join('\n');
}

/// 成品行「产出去向」格的摘要：转下一道工序几个工单共多少、送入仓库多少。
String outputAllocationSummary(DailyGridRow product) {
  var direct = 0.0;
  var receivers = 0;
  var warehouse = 0.0;
  for (final allocation in product.allocationRows) {
    final qty = double.tryParse(allocation.allocationQty.text.trim()) ?? 0;
    if (!qty.isFinite || qty <= 0) continue;
    if (allocation.allocationDemandId == null) {
      warehouse += qty;
    } else {
      direct += qty;
      receivers++;
    }
  }
  return [
    if (receivers > 0) '转下一道工序 $receivers 个工单 ${_quantityText(direct)}',
    if (warehouse > 0) '送入仓库 ${_quantityText(warehouse)}',
  ].join(' · ');
}

/// 去向分配子行的下拉条目：可送的上层工单(先急后缓，「还差 N」/「已分满」)、
/// 不能收的上层工单(置灰红字写原因)、送入仓库。
List<UtenDropdownItem> outputAllocationOptions(DailyGridRow allocation) {
  final parent = allocation.allocationParent!;
  final siblings = {
    for (final other in parent.allocationRows)
      if (!identical(other, allocation) &&
          other.allocationDemandId != null &&
          outputAllocationVisible(other))
        other.allocationDemandId!,
  };
  final receivers =
      siblings.length + (allocation.allocationDemandId == null ? 0 : 1);
  final items = <UtenDropdownItem>[];
  for (final candidate in parent.directTransferCandidates) {
    final current = candidate.demandId == allocation.allocationDemandId;
    final room = parent.directTransferRoomBase[candidate.demandId] ?? 0;
    final full = room <= 0.0000001;
    final taken = siblings.contains(candidate.demandId);
    final atLimit =
        !current &&
        allocation.allocationDemandId == null &&
        receivers >= parent.directTransferReceiverLimit;
    final label = candidate.optionLabel(room);
    items.add(
      UtenDropdownItem(
        value: candidate.demandId,
        enabled: current || (!full && !taken && !atLimit),
        label: current
            ? label
            : taken
            ? '$label · 本行已分给它'
            : full
            ? '${candidate.optionLabel(0).replaceFirst(RegExp(r' · 还差 [^·]*'), '')} · 已分满'
            : atLimit
            ? '$label · 一行最多转给 ${parent.directTransferReceiverLimit} 个工单'
            : label,
      ),
    );
  }
  final listed = {for (final item in items) item.value};
  // 原来选的上层工单现在不在可送名单里(草稿重开后失效)：保留它的显示，让人自己改。
  // 候选读取失败时只是暂时核对不了，不能说成「不能收」，也不标红。
  final currentId = allocation.allocationDemandId;
  if (currentId != null && !listed.contains(currentId)) {
    final blocked = parent.directTransferBlockedTargets
        .where((target) => target.demandId == currentId)
        .firstOrNull;
    final unread = parent.directTransferLoadFailed;
    items.add(
      UtenDropdownItem(
        value: currentId,
        enabled: false,
        error: !unread,
        label:
            blocked?.optionLabel ??
            (unread ? '原来选的上层工单(候选读取失败，暂时无法核对)' : '原来选的上层工单现在不能收，请重新选择'),
      ),
    );
    listed.add(currentId);
  }
  for (final target in parent.directTransferBlockedTargets) {
    if (listed.contains(target.demandId)) continue;
    items.add(
      UtenDropdownItem(
        value: target.demandId,
        enabled: false,
        error: true,
        label: target.optionLabel,
      ),
    );
  }
  items.add(
    const UtenDropdownItem(
      value: outputAllocationWarehouseValue,
      label: '送入仓库',
    ),
  );
  return items;
}

/// 去向分配子行「产出去向」格的文字(列宽测量用，与下拉收起态同一份)。
String _allocationOptionText(DailyGridRow allocation) {
  final demandId = allocation.allocationDemandId;
  if (demandId == null) return '送入仓库';
  for (final item in outputAllocationOptions(allocation)) {
    if (item.value == demandId) return item.label;
  }
  return '';
}

/// 只读主档字段单元格（颜色/单位自动回填后用）：显示 entries[id] 名，空显示「—」。
Widget _readOnlyMasterCell(
  BuildContext context,
  ValueNotifier<String?> notifier,
  Map<String, String> entries,
) {
  final theme = Theme.of(context);
  return ValueListenableBuilder<String?>(
    valueListenable: notifier,
    builder: (context, id, _) {
      final name = (id != null && id.isNotEmpty) ? entries[id] : null;
      final hasName = name != null && name.isNotEmpty;
      return Text(
        hasName ? name : '—',
        style: TextStyle(
          color: hasName ? null : theme.colorScheme.onSurfaceVariant,
        ),
      );
    },
  );
}

/// 「产出去向」格的读取失败提示：单行省略，整句放在悬停提示里。
class DirectTransferBlockedText extends StatelessWidget {
  const DirectTransferBlockedText(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: text,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ),
    );
  }
}
