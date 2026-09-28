// 生产日报明细可编辑表的行模型 + 列定义（UtenEditableGrid 用）。
//
// 日报记录非金额生产计量事实：完工申报量及可选实际总重量。
// 客户端单价/金额不是计件工资权威，已从操作界面移除。
// DailyGridRow：货品(选择)/完工申报量/实际重量；颜色/单位选货品后自动回填（只读）；
// 精确来源子任务链接 + 备注。历史完结事实保留，不再作为新报工入口。
import 'package:flutter/material.dart';
import '../../../shared/presentation/workflow_field_guidance.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';

import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/widgets/uten_tree_table_cell.dart';
import '../models/daily_output_allocation.dart'
    show outputAllocationQuantityText;
import '../models/production_direct_transfer_candidate.dart';
import '../models/production_daily_report.dart';
import '../repositories/production_material_repository.dart';

/// One editable fact per demand, shared by all displayed output slices.
class DailyMaterialInput {
  final used = TextEditingController();
  final autofilled = ValueNotifier<bool>(false);
  String? autofillText;
  double? manualRatio;
  bool manuallyEdited = false;

  void dispose() {
    used.dispose();
    autofilled.dispose();
  }
}

/// 生产日报明细行。货品用 ValueNotifier（点选后单元格自动刷新）；
/// 完工量是生产声明；颜色/单位为来源任务冻结值。
class DailyGridRow extends EditableGridRow {
  final ValueNotifier<GoodsOption?> goodsNotifier = ValueNotifier<GoodsOption?>(
    null,
  );
  GoodsOption? get goods => goodsNotifier.value;
  set goods(GoodsOption? v) => goodsNotifier.value = v;

  final TextEditingController qty = TextEditingController(); // 完工量
  final TextEditingController weight = TextEditingController(); // 本行实际总重量
  final TextEditingController planNo = TextEditingController(); // 关联生产计划号
  final TextEditingController remark = TextEditingController();

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
  double? orderQty;
  double? maxReportQty;
  bool allowActualOverproduction = false;
  String? supplementRequestId;
  String? supplementProofId;
  double? supplementApprovedActualQty;
  bool get hasFixedSupplement =>
      !isFqcRecovery &&
      (supplementProofId != null ||
          (supplementRequestId != null && supplementApprovedActualQty != null));
  bool get hasReportQuantityLimit =>
      isFqcRecovery ||
      (!allowActualOverproduction && supplementProofId == null);

  /// Remaining output target, distinct from this delivery's material capacity.
  double? remainingPlanQty;
  bool legacyManual = false;

  // ===== V583 物料子行 / V736 去向分配子行：报工、去向与实际用料合并到同一张表 =====
  // 一张表只能有一个泛型行类型，所以成品行与两种子行共用本类，由 [depth] 区分：
  // 0 = 成品报工行(原有全部字段)，1 = 挂在它下面的子行——去向分配子行([allocationParent] 非空)
  // 或物料子行(其余)。各列的 cellBuilder 按行种分支，用不到的格返回空。

  /// 0 = 成品报工行；1 = 挂在成品行下面的子行(去向分配或物料)。
  int depth = 0;

  /// 挂在成品行下面的子行(去向分配或物料)。成品行的校验、行号、勾选都只看 depth=0 的行。
  bool get isSubRow => depth > 0;

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

  /// 成品行「产出去向」格的红字：「无法转到下一道工序：<服务端原因>」或候选读取失败提示；
  /// 为空 = 有可送的上层工单，或还没读过候选(没选来源/货品)。
  String? directTransferBlockedText;

  /// 最近一次候选读取失败：此时不知道能不能转，不替人改已定的去向。
  bool directTransferLoadFailed = false;

  /// 候选已读到且一个可送的都没有：只能送入仓库，去向子行不给下拉。
  bool get directTransferUnavailable =>
      directTransferBlockedText != null && !directTransferLoadFailed;

  /// 成品行：去向分配子行(显示顺序)。
  List<DailyGridRow> allocationRows = [];

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

  /// 物料子行(挂在成品行下、不是去向分配的子行)。
  bool get isMaterialRow => depth > 0 && !isAllocationRow;

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

  double? get materialUsedValue => double.tryParse(materialUsed.text.trim());

  bool get materialInvalid {
    if (!materialEditable) return false;
    final value = materialUsedValue;
    return value == null ||
        !value.isFinite ||
        value < 0 ||
        value - materialCap > 0.0000001;
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
      ..orderQty = orderQty
      ..maxReportQty = maxReportQty
      ..allowActualOverproduction = allowActualOverproduction
      ..supplementRequestId = null
      ..supplementProofId = null
      ..supplementApprovedActualQty = null
      ..remainingPlanQty = remainingPlanQty
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
    c.weight.text = weight.text;
    c.planNo.text = planNo.text;
    c.remark.text = remark.text;
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
        ..remainingPlanQty = null
        ..allowActualOverproduction = false
        ..planNo.clear();
    }
    return c;
  }

  /// 颜色/单位（选货品后自动回填；单元格只读显示）。
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

  @override
  void dispose() {
    goodsNotifier.dispose();
    colorIdNotifier.dispose();
    unitIdNotifier.dispose();
    finalNotifier.dispose();
    qty.dispose();
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
    final qty = (entry['qty'] as num?)?.toDouble();
    if (qty == null || !qty.isFinite || qty <= 0) continue;
    final row = DailyGridRow()
      ..depth = 1
      ..allocationParent = product
      ..allocationDemandId = entry['directTransferDemandId'] as String?
      ..allocationFixed = true
      ..allocationRequested = qty;
    row.allocationQty.text = _quantityText(qty);
    rows.add(row);
  }
  product.allocationRows = rows;
}

/// 去向分配子行只在「有得选」时显示：有可送的上层工单，或已有转给上层工单的条目、或不止一条；
/// 只有一条「送入仓库」时由成品行的摘要或红字说明，不另占一行(顶层产品、委外件等不添噪音)。
bool showsOutputAllocations(DailyGridRow product) {
  final visible = product.allocationRows.where(outputAllocationVisible);
  return product.directTransferCandidates.isNotEmpty ||
      visible.length > 1 ||
      visible.any((row) => row.allocationDemandId != null);
}

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
          'qty': double.parse(allocation.allocationQty.text.trim()),
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
) {
  final parents = <DailyGridRow>{
    for (final row in rows)
      if (row.material?.demandId == demandId &&
          submitted.contains(row.materialParent))
        row.materialParent!,
  };
  return parents.fold(0, (total, row) {
    final qty = double.tryParse(row.qty.text.trim());
    return total + (qty != null && qty.isFinite && qty > 0 ? qty : 0);
  });
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

/// Keep stored draft use when a transient read failure hides its editor.
/// Only a successfully resolved change of output sources can remove old use.
List<Map<String, dynamic>> mergeDraftMaterialUsages({
  required Iterable<ProductionDailyReportMaterialUsage> saved,
  required Iterable<Map<String, dynamic>> edited,
  Set<String>? allowedSourceSegmentIds,
}) {
  final quantities = <String, double>{
    for (final usage in saved)
      if (allowedSourceSegmentIds == null ||
          usage.materialExecutionSegmentId == null ||
          allowedSourceSegmentIds.contains(usage.materialExecutionSegmentId))
        usage.demandId: usage.qtyBase,
  };
  for (final line in edited) {
    quantities[line['demandId'] as String] = (line['qtyBase'] as num)
        .toDouble();
  }
  return [
    for (final entry in quantities.entries)
      {'demandId': entry.key, 'qtyBase': entry.value},
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
  if (!reportedQty.isFinite || reportedQty <= 0) return null;
  // Exact package/batch quantities cannot be prorated, even from a prior edit.
  if (material.requirementMode != 'LINEAR') return null;
  final ratio = ratioOverride ?? materialUsagePerProduct(material);
  if (ratio == null || !ratio.isFinite || ratio < 0) return null;
  final raw = reportedQty * ratio;
  final capped = raw > material.availableToSettleQty
      ? material.availableToSettleQty
      : raw;
  return (capped * 10000).roundToDouble() / 10000;
}

/// 生产日报明细列：货品（点选）/ 颜色（只读）/ 单位（只读）/ 完工申报量 / 实际重量 /
/// 关联计划号 / 备注。[onPickGoods] 由编辑页提供；[colorEntries]/[unitEntries] 由编辑页注入。
/// [hasSubRows]/[isLastSubRow] 由编辑页按当前行序计算：本表把成品行与
/// 它的物料子行扁平混排，树形缩进和连接线要知道「这行下面还有没有子行」「这是不是
/// 最后一个子行」。[onMaterialChanged] 让编辑页在实耗输入变化时重算必填红框与提交态。
List<EditableGridColumn<DailyGridRow>> dailyGridColumns({
  required BuildContext context,
  required Future<void> Function(DailyGridRow row) onPickGoods,
  required Future<void> Function(DailyGridRow row) onPickSource,
  required void Function(DailyGridRow row) onClearSource,
  Future<void> Function(DailyGridRow row)? onOpenSource,
  required Map<String, String> colorEntries,
  required Map<String, String> unitEntries,
  bool Function(DailyGridRow row)? hasSubRows,
  bool Function(DailyGridRow row)? isLastSubRow,
  void Function()? onMaterialChanged,
  void Function(DailyGridRow allocation, String? demandId)?
  onAllocationDestinationChanged,
  void Function(DailyGridRow allocation)? onAllocationQtyChanged,
  void Function(DailyGridRow allocation, bool focused)? onAllocationQtyFocus,
}) {
  // 列说明统一挂表头 ⓘ（2026-09-09 口径）：每行重复的 ⓘ 既冗余又挤占格宽。
  final l10n = workflowFieldText(context);
  return [
    EditableGridColumn<DailyGridRow>(
      key: 'goods',
      label: '货品名称 / 用料',
      // V583 起本列要容下物料子行的树形缩进(16)+ 叶子位(48)：树单元的缩进与
      // 图标位不进 textOf 的自动量宽，宽度只能硬给，否则物料名一律被挤成省略号。
      width: 320,
      required: true,
      // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色**各占一列**。
      // 报工行多由来源子任务冻结带入，同名不同色/不同编号的货品只看名称会报到
      // 别的货上；这里只放名称，编号见下一列，颜色/单位本表本来就有独立列。
      textOf: (r) => r.isAllocationRow
          ? '产出去向'
          : r.isMaterialRow
          ? (r.material?.goodsName ?? '')
          : (r.goods?.name ?? ''),
      listenableOf: (r) => r.goodsNotifier,
      // 格尾树形/选择图标计入量宽（2026-09-16）；物料子行的树缩进仍由基础宽兜。
      chromeWidth: UtenEditableGridCellSpec.dropdownChevronWidth,
      cellBuilder: (context, row) {
        if (row.isAllocationRow) {
          return UtenTreeTableCell(
            depth: 1,
            sequence: '',
            sequenceInline: true,
            showLeafMarker: false,
            guideBleed: UtenEditableGrid.cellVerticalPadding,
            isLastChild: isLastSubRow?.call(row) ?? true,
            title: '产出去向',
          );
        }
        if (row.isMaterialRow) {
          return UtenTreeTableCell(
            depth: 1,
            sequence: '',
            sequenceInline: true,
            showLeafMarker: false,
            // 连接线要跨过宿主数据格的纵向内边距才连成一条而不是虚线；
            // 数值取自表格组件公开的常量，不在调用点抄魔数（2026-09-15）。
            guideBleed: UtenEditableGrid.cellVerticalPadding,
            isLastChild: isLastSubRow?.call(row) ?? true,
            title: row.material?.goodsName ?? '未命名物料',
            subtitle: row.materialShared
                ? '沿用前批已领 · ${row.materialSegmentLabel}'
                : '本工单领用',
          );
        }
        return RequiredCellFrame(
          listenable: row.goodsNotifier,
          isEmpty: () => row.goods == null,
          child: InkWell(
            onTap: row.hasLinkedSource ? null : () => onPickGoods(row),
            child: InputDecorator(
              decoration: const InputDecoration(isDense: true),
              child: Row(
                children: [
                  Expanded(
                    child: ValueListenableBuilder<GoodsOption?>(
                      valueListenable: row.goodsNotifier,
                      builder: (context, g, _) => g == null
                          ? Text(
                              '点击选择',
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
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
      textOf: (r) => r.isAllocationRow
          ? ''
          : r.isMaterialRow
          ? (r.material?.goodsCode ?? '')
          : (r.goods?.code ?? ''),
      listenableOf: (r) => r.goodsNotifier,
      cellBuilder: (context, row) => row.isAllocationRow
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
      textOf: (r) => r.isAllocationRow
          ? ''
          : r.isMaterialRow
          ? (r.material?.colorName ?? '')
          : (colorEntries[r.colorId ?? ''] ?? ''),
      listenableOf: (r) => r.colorIdNotifier,
      cellBuilder: (context, row) => row.isAllocationRow
          ? const SizedBox.shrink()
          : row.isMaterialRow
          ? UtenGoodsAttributeCell(row.material?.colorName)
          : _readOnlyMasterCell(context, row.colorIdNotifier, colorEntries),
    ),
    EditableGridColumn<DailyGridRow>(
      key: 'unit',
      label: '单位',
      width: 110,
      textOf: (r) => r.isAllocationRow
          ? ''
          : r.isMaterialRow
          ? (r.material?.unitName ?? '')
          : (unitEntries[r.unitId ?? ''] ?? ''),
      listenableOf: (r) => r.unitIdNotifier,
      cellBuilder: (context, row) => row.isAllocationRow
          ? const SizedBox.shrink()
          : row.isMaterialRow
          ? Text(row.material?.unitName ?? '—')
          : _readOnlyMasterCell(context, row.unitIdNotifier, unitEntries),
    ),
    EditableGridColumn<DailyGridRow>(
      key: 'qty',
      label: '完工申报量',
      width: 118,
      numeric: true,
      required: true,
      headerInfo: l10n.workflowReportQuantityHint,
      cellBuilder: (context, row) => row.isSubRow
          ? const SizedBox.shrink()
          : RequiredCellFrame(
              listenable: row.qty,
              isEmpty: () => (double.tryParse(row.qty.text.trim()) ?? 0) <= 0,
              child: TextField(
                controller: row.qty,
                readOnly: row.hasFixedSupplement,
                textAlign: TextAlign.right,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const UtenInputDecoration(
                  InputDecoration(isDense: true, hintText: '0'),
                ),
              ),
            ),
    ),
    // ===== V583 物料子行专用两列：成品行留空 =====
    EditableGridColumn<DailyGridRow>(
      key: 'issuedQty',
      label: '领料量',
      width: 104,
      numeric: true,
      headerInfo:
          '仓库已实际发给本工单的数量(基本单位)。它是只读事实，'
          '要改只能走仓库的出库红冲。',
      textOf: (r) =>
          r.isMaterialRow ? _quantityText(r.material?.issuedQty ?? 0) : '',
      cellBuilder: (context, row) => row.isMaterialRow
          ? Text(_quantityText(row.material?.issuedQty ?? 0))
          : const SizedBox.shrink(),
    ),
    EditableGridColumn<DailyGridRow>(
      key: 'materialUsed',
      label: '本次实际用料',
      width: 140,
      numeric: true,
      required: true,
      headerInfo:
          '填本次这张报工真正用掉的数量，允许填 0(这批料一点没用)。'
          '上限是「本次还能登记多少」——已提交待仓库收料的部分不能再记成消耗。'
          '最后一次报工时，剩下没登记的会问你要不要退回仓库。',
      cellBuilder: (context, row) {
        if (!row.isMaterialRow) return const SizedBox.shrink();
        if (!row.materialOwnsInput) {
          // 同一工单已在上面某个成品行下登记过：这里只回显，不重复占额度。
          return Tooltip(
            message: '本工单的物料已在上面的成品行下登记，这里只作对照',
            child: Text(
              _quantityText(row.materialUsedValue ?? 0),
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
              textAlign: TextAlign.right,
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
                    hintText: '0',
                    helper: autofilled
                        ? const UtenFieldMessage.autofill(
                            '已按完工申报量 × 单耗自动算出，请核对本次实际用料；'
                            '未修改的建议随产量更新，手工填写后保持原值',
                          )
                        : null,
                  ),
                  info: row.materialReadOnly
                      ? null
                      : row.material?.requirementMode == 'LINEAR'
                      ? '可登记 ${_quantityText(row.materialCap)}；实际工艺耗用含 BOM 已计入的正常损耗'
                      : '整包、固定批次或缺少计量依据不能按平均单耗估算。请填写实际工艺耗用（可填 0），可登记 ${_quantityText(row.materialCap)}',
                ),
                Theme.of(context),
                autofilled: autofilled && !row.materialReadOnly,
              ),
            ),
          ),
        );
      },
    ),
    // ===== V736/ADR-127 产出去向两列：成品行写摘要或红字，去向分配子行可改，物料子行留空 =====
    EditableGridColumn<DailyGridRow>(
      key: 'destination',
      label: '产出去向',
      width: 300,
      headerInfo:
          '实际产量分到哪里：「转下一道工序」= 班组自检合格后不入库，直接交给本车间的上层工单'
          '(父件)，审核时自动放行、入本车间线边仓并投入；「送入仓库」= 交仓库送检、品质检验、点收入库。\n'
          '系统按先急后缓把本行产量逐个分给还缺料的上层工单(黄框为系统建议)，分不完的送入仓库；'
          '改任一条的去向或数量，下面会自动补一条接着分，直到分完。\n'
          '下拉里「已分满」表示本张报工其它行已把它分满；红字是不能收的原因(例如委外件要先送入仓库、'
          '上层工单在别的车间)。计划内公共备货与超出计划的产量一律送入仓库。',
      textOf: (r) => r.isAllocationRow
          ? _allocationOptionText(r)
          : r.isMaterialRow
          ? ''
          : (r.directTransferBlockedText ?? outputAllocationSummary(r)),
      listenableOf: (r) =>
          r.isAllocationRow ? r.allocationDemandNotifier : r.allocationRevision,
      chromeWidth: UtenEditableGridCellSpec.dropdownChevronWidth,
      cellBuilder: (context, row) {
        if (row.isMaterialRow) return const SizedBox.shrink();
        if (!row.isAllocationRow) {
          return ValueListenableBuilder<int>(
            valueListenable: row.allocationRevision,
            builder: (context, _, _) {
              final blocked = row.directTransferBlockedText;
              // 不能转(或候选读不到)：红字写明原因，整句放在悬停提示里防截断。
              if (blocked != null) return DirectTransferBlockedText(blocked);
              final summary = outputAllocationSummary(row);
              return Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  summary.isEmpty ? '—' : summary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              );
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
                // 服务端判定一个可送的上层工单都没有：只能送入仓库，不给下拉(原因在成品行红字)。
                if (parent.directTransferUnavailable &&
                    row.allocationDemandId == null) {
                  return const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('送入仓库', maxLines: 1),
                  );
                }
                return UtenDropdownField(
                  key: ValueKey(
                    'daily-allocation-destination-${identityHashCode(row)}',
                  ),
                  dense: true,
                  allowClear: false,
                  value:
                      row.allocationDemandId ?? outputAllocationWarehouseValue,
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
                );
              },
            ),
          ),
        );
      },
    ),
    EditableGridColumn<DailyGridRow>(
      key: 'allocationQty',
      label: '去向数量',
      width: 120,
      numeric: true,
      headerInfo:
          '这一条去向分多少(与完工申报量同单位)。所有去向合计始终等于本行完工申报量：'
          '改大会压低下面的条目，改小则多出来的自动排到下面(先急后缓的下一个上层工单，没有就送入仓库)；'
          '改成 0 的条目会消失。转给上层工单的数量不能超过它还差的数量。',
      textOf: (r) => r.isAllocationRow ? r.allocationQty.text : '',
      listenableOf: (r) => r.allocationQty,
      cellBuilder: (context, row) {
        if (!row.isAllocationRow) return const SizedBox.shrink();
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
                textAlign: TextAlign.right,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => onAllocationQtyChanged?.call(row),
                decoration: applyAutofillHint(
                  UtenInputDecoration(
                    InputDecoration(
                      isDense: true,
                      hintText: '0',
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
                            label.isEmpty ? '点击选择' : label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
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
              decoration: const InputDecoration(isDense: true),
            ),
    ),
  ];
}

/// 数量文本：整数不带小数点，小数最多 4 位且不留尾零(与全站数量显示同口径)。
String _quantityText(double value) => outputAllocationQuantityText(value);

/// 去向下拉里「送入仓库」那一项的值(下拉值不能为空，用它代表「不转给任何上层工单」)。
const outputAllocationWarehouseValue = '__WAREHOUSE__';

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

/// 「转给工单」格的不可转红字(V736/ADR-127)：单行省略，整句放在悬停提示里。
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
