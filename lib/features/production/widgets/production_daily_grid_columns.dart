// 生产日报明细可编辑表的行模型 + 列定义（UtenEditableGrid 用）。
//
// 日报记录非金额生产计量事实：完工申报量及可选实际总重量。
// 客户端单价/金额不是计件工资权威，已从操作界面移除。
// DailyGridRow：货品(选择)/完工申报量/实际重量；颜色/单位选货品后自动回填（只读）；
// 精确来源子任务链接 + 备注。历史完结事实保留，不再作为新报工入口。
import 'package:flutter/material.dart';
import '../../../shared/presentation/workflow_field_guidance.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';

import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/widgets/uten_tree_table_cell.dart';
import '../models/production_direct_transfer_candidate.dart';
import '../models/production_daily_report.dart';
import '../repositories/production_material_repository.dart';

/// One editable fact per demand, shared by all displayed output slices.
class DailyMaterialInput {
  final used = TextEditingController();
  final autofilled = ValueNotifier<bool>(false);
  String? autofillText;
  double? manualRatio;

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

  /// Remaining output target, distinct from this delivery's material capacity.
  double? remainingPlanQty;
  bool legacyManual = false;

  // ===== V583 物料子行：报工与实际用料合并到同一张表 =====
  // 一张表只能有一个泛型行类型，所以成品行与物料子行共用本类，由 [depth] 区分：
  // 0 = 成品报工行(原有全部字段)，1 = 挂在它下面的物料子行(只用下面这几个)。
  // 各列的 cellBuilder 按 depth 分支，用不到的格返回空。

  /// 0 = 成品报工行；1 = 该成品所属工单已领用的物料子行。
  int depth = 0;

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

  // ===== V584/V585 产出去向：送仓库 还是 转下一道工序(同车间内部直送) =====
  // 一行只有一个去向，要拆量就拆行——送检登记与检验都按报工行唯一，行内拆量
  // 要同时改两处唯一性。

  /// 'WAREHOUSE' = 送入仓库(默认，走品质部)；'WORKSHOP' = 转下一道工序。
  final ValueNotifier<String> destinationNotifier = ValueNotifier<String>(
    'WAREHOUSE',
  );
  String get destination => destinationNotifier.value;
  set destination(String value) => destinationNotifier.value = value;
  bool get isDirectTransfer => destination == 'WORKSHOP';

  /// 转送时投给哪条上层物料需求。候选由服务端按同车间同货品给出。
  final ValueNotifier<ProductionDirectTransferCandidate?>
  directTransferNotifier = ValueNotifier<ProductionDirectTransferCandidate?>(
    null,
  );
  ProductionDirectTransferCandidate? get directTransfer =>
      directTransferNotifier.value;
  set directTransfer(ProductionDirectTransferCandidate? value) =>
      directTransferNotifier.value = value;

  /// 本行可选的上层工单；空列表 = 这一行没有同车间的上层工单可转。
  List<ProductionDirectTransferCandidate> directTransferCandidates = const [];
  int directTransferRequestVersion = 0;

  // ===== V595 记忆与自动计算：黄框 + 警示图标提醒核对，用户改动即清除 =====

  /// 「产出去向」由上次报工记忆带入。
  final ValueNotifier<bool> destinationAutofilled = ValueNotifier<bool>(false);

  /// 「转给工单」由上次报工记忆带入。
  final ValueNotifier<bool> directTransferAutofilled = ValueNotifier<bool>(
    false,
  );

  /// 用户已亲手选过去向/接收工单：换来源前记忆不再覆盖。
  bool destinationTouched = false;

  /// 编辑既有草稿时回填用：候选加载后按这个需求 UUID 选中原接收工单，不标黄。
  String? pendingDirectTransferDemandId;

  /// 本次实际用料由完工申报量按单耗自动算出(物料子行)。
  ValueNotifier<bool> get materialUsageAutofilled => _materialInput.autofilled;

  /// 自动算出的文本；当前文本与它不同即视为用户改过。
  String? get materialAutofillText => _materialInput.autofillText;
  set materialAutofillText(String? value) =>
      _materialInput.autofillText = value;

  /// 用户手改后的「用料 / 完工量」比例：完工量再变时按它等比换算并重新标黄。
  double? get materialManualRatio => _materialInput.manualRatio;
  set materialManualRatio(double? value) => _materialInput.manualRatio = value;

  bool get isMaterialRow => depth > 0;

  /// 物料所属工单的可读标识(子计划号，取不到时退回 UUID 前 8 位)。
  String get materialSegmentLabel {
    final code = material?.executionSegmentCode;
    if (code != null && code.trim().isNotEmpty) return code.trim();
    final id = material?.executionSegmentId;
    return id == null || id.length < 8 ? '原领料工单' : id.substring(0, 8);
  }

  /// 可填的物料子行(自己负责提交且有权限)：必填红框与提交校验都只认这些行。
  bool get materialEditable =>
      isMaterialRow && materialOwnsInput && !materialReadOnly;

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
  /// 物料子行不参与复制粘贴：它由来源工单派生，复制出来的第二份会把同一份额度
  /// 当成两份填。页面已用 canSelectRow 挡住勾选，这里再兜一次底。
  DailyGridRow clone() {
    if (isMaterialRow) {
      throw UnsupportedError('物料子行由来源工单派生，不支持复制');
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
      ..remainingPlanQty = remainingPlanQty
      ..destination = destination
      ..destinationTouched = destinationTouched
      ..directTransfer = directTransfer
      ..pendingDirectTransferDemandId = pendingDirectTransferDemandId
      ..directTransferCandidates = List.of(directTransferCandidates)
      ..legacyManual = legacyManual
      ..goods = goods
      ..colorId = colorId
      ..unitId = unitId
      ..isFinal = false;
    c.qty.text = qty.text;
    c.weight.text = weight.text;
    c.planNo.text = planNo.text;
    c.remark.text = remark.text;
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
    destinationNotifier.dispose();
    directTransferNotifier.dispose();
    destinationAutofilled.dispose();
    directTransferAutofilled.dispose();
    super.dispose();
  }
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
  if (row.isMaterialRow || row.isFqcRecovery) return false;
  final remaining = row.remainingPlanQty;
  final segment = row.executionSegmentId;
  if (segment == null) return false;
  var total = 0.0;
  for (final candidate in rows) {
    if (candidate.isMaterialRow ||
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

double? productionReportBaseQuantity(DailyGridRow row) {
  final qty = double.tryParse(row.qty.text.trim());
  final rate = row.unitRate ?? 1;
  if (qty == null || !qty.isFinite || qty <= 0 || !rate.isFinite || rate <= 0) {
    return null;
  }
  final baseUnits = financeExactProductUnits(qty.toString(), rate.toString());
  if (baseUnits == null || baseUnits <= BigInt.zero) return null;
  final rounded = baseUnits.toDouble() / 10000;
  return rounded.isFinite ? rounded : null;
}

/// An explicit destination may become invalid, but must never change silently.
bool restoreExplicitDirectTransferSelection(DailyGridRow row) {
  if (!row.destinationTouched) return false;
  final requestedId =
      row.pendingDirectTransferDemandId ?? row.directTransfer?.demandId;
  row.directTransfer = null;
  if (row.isDirectTransfer && requestedId != null) {
    row.pendingDirectTransferDemandId = requestedId;
    for (final candidate in row.directTransferCandidates) {
      if (candidate.demandId == requestedId) {
        row.directTransfer = candidate;
        row.pendingDirectTransferDemandId = null;
        break;
      }
    }
  }
  row.destinationAutofilled.value = false;
  row.directTransferAutofilled.value = false;
  return true;
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

List<String> directTransferAggregateIssues(Iterable<DailyGridRow> rows) {
  final bySource = <(String?, String), List<DailyGridRow>>{};
  final byDemand = <String, List<DailyGridRow>>{};
  for (final row in rows) {
    if (row.isMaterialRow ||
        !row.isDirectTransfer ||
        row.directTransfer == null) {
      continue;
    }
    final demandId = row.directTransfer!.demandId;
    bySource
        .putIfAbsent((
          row.planItemId ?? row.executionSegmentId,
          demandId,
        ), () => [])
        .add(row);
    byDemand.putIfAbsent(demandId, () => []).add(row);
  }
  final issues = <String>[];
  for (final group in bySource.values.where((group) => group.length > 1)) {
    var total = 0.0;
    var limit = double.infinity;
    for (final row in group) {
      total += productionReportBaseQuantity(row) ?? 0;
      final remaining = row.directTransfer!.remainingQty;
      if (remaining < limit) limit = remaining;
    }
    if (total > limit + 0.000001) {
      issues.add(
        '${group.length} 行投给同一接收需求，基础数量合计 ${_quantityText(total)} '
        '超过本来源可直送 ${_quantityText(limit)}，请合计核对',
      );
    }
  }
  for (final group in byDemand.values.where((group) => group.length > 1)) {
    var total = 0.0;
    double? limit;
    for (final row in group) {
      total += productionReportBaseQuantity(row) ?? 0;
      final target = row.directTransfer!;
      // Older clients may lack the aggregate demand snapshot. The server still
      // validates it; a source-specific quota must never substitute for it.
      if (target.requiredQty > 0 &&
          target.requiredQty.isFinite &&
          target.alreadyCoveredQty.isFinite &&
          target.alreadyCoveredQty >= 0) {
        final available = (target.requiredQty - target.alreadyCoveredQty).clamp(
          0.0,
          double.infinity,
        );
        if (limit == null || available < limit) limit = available;
      }
    }
    if (limit != null && total > limit + 0.000001) {
      issues.add(
        '同一接收需求本次基础数量合计 ${_quantityText(total)} '
        '超过其总缺口 ${_quantityText(limit)}，请合计核对',
      );
    }
  }
  return issues;
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
/// [hasMaterialChildren]/[isLastMaterialChild] 由编辑页按当前行序计算：本表把成品行与
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
  bool Function(DailyGridRow row)? hasMaterialChildren,
  bool Function(DailyGridRow row)? isLastMaterialChild,
  void Function()? onMaterialChanged,
  void Function(DailyGridRow row, String destination)? onDestinationChanged,
  void Function(DailyGridRow row, ProductionDirectTransferCandidate picked)?
  onDirectTransferPicked,
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
      textOf: (r) => r.isMaterialRow
          ? (r.material?.goodsName ?? '')
          : (r.goods?.name ?? ''),
      listenableOf: (r) => r.goodsNotifier,
      // 格尾树形/选择图标计入量宽（2026-09-16）；物料子行的树缩进仍由基础宽兜。
      chromeWidth: UtenEditableGridCellSpec.dropdownChevronWidth,
      cellBuilder: (context, row) {
        if (row.isMaterialRow) {
          return UtenTreeTableCell(
            depth: 1,
            sequence: '',
            sequenceInline: true,
            showLeafMarker: false,
            // 连接线要跨过宿主数据格的纵向内边距才连成一条而不是虚线；
            // 数值取自表格组件公开的常量，不在调用点抄魔数（2026-09-15）。
            guideBleed: UtenEditableGrid.cellVerticalPadding,
            isLastChild: isLastMaterialChild?.call(row) ?? true,
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
                  if (hasMaterialChildren?.call(row) ?? false)
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
      textOf: (r) => r.isMaterialRow
          ? (r.material?.goodsCode ?? '')
          : (r.goods?.code ?? ''),
      listenableOf: (r) => r.goodsNotifier,
      cellBuilder: (context, row) => row.isMaterialRow
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
      textOf: (r) => r.isMaterialRow
          ? (r.material?.colorName ?? '')
          : (colorEntries[r.colorId ?? ''] ?? ''),
      listenableOf: (r) => r.colorIdNotifier,
      cellBuilder: (context, row) => row.isMaterialRow
          ? UtenGoodsAttributeCell(row.material?.colorName)
          : _readOnlyMasterCell(context, row.colorIdNotifier, colorEntries),
    ),
    EditableGridColumn<DailyGridRow>(
      key: 'unit',
      label: '单位',
      width: 110,
      textOf: (r) => r.isMaterialRow
          ? (r.material?.unitName ?? '')
          : (unitEntries[r.unitId ?? ''] ?? ''),
      listenableOf: (r) => r.unitIdNotifier,
      cellBuilder: (context, row) => row.isMaterialRow
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
      cellBuilder: (context, row) => row.isMaterialRow
          ? const SizedBox.shrink()
          : RequiredCellFrame(
              listenable: row.qty,
              isEmpty: () => (double.tryParse(row.qty.text.trim()) ?? 0) <= 0,
              child: TextField(
                controller: row.qty,
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
                            '完工申报量改了会按比例重算',
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
    // ===== V584/V585 产出去向两列：物料子行留空 =====
    EditableGridColumn<DailyGridRow>(
      key: 'destination',
      label: '产出去向',
      width: 185,
      headerInfo:
          '「送入仓库」= 交仓库送检登记、品质部检验、点收入库(默认)。\n'
          '「转下一道工序」= 班组自检合格后不入库，直接投给**本车间**的上层工单'
          '(父件)；审核时自动完成放行、入本车间线边仓和投入，不用再走领料。'
          '线边仓由系统按车间自动配置，不用去仓库资料里建。\n'
          '上次报工的去向会自动带入并标黄，改动即清除提醒。\n'
          '跨车间必须走仓库——料离开本车间就脱离同一批人的视线。',
      textOf: (r) =>
          r.isMaterialRow ? '' : (r.isDirectTransfer ? '转下一道工序' : '送入仓库'),
      listenableOf: (r) => r.destinationNotifier,
      // 下拉格右侧展开箭头(20)计入自动加宽量宽。
      chromeWidth: UtenEditableGridCellSpec.dropdownChevronWidth,
      cellBuilder: (context, row) {
        if (row.isMaterialRow) return const SizedBox.shrink();
        return ValueListenableBuilder<String>(
          valueListenable: row.destinationNotifier,
          builder: (context, value, _) {
            final canTransfer = row.directTransferCandidates.isNotEmpty;
            // 2026-09-16 用户口径：本文件内表格下拉已统一用自家 UtenDropdownField
            //（统一弹层/单行省略号/列宽自适应），不再出现原生
            // DropdownButtonFormField（全站其余处的替换由下拉组件批次负责）。
            return ValueListenableBuilder<bool>(
              valueListenable: row.destinationAutofilled,
              builder: (context, autofilled, _) => UtenDropdownField(
                dense: true,
                value: value,
                // V595 记忆预填：黄框 + 警示图标提醒核对(与带记忆的框同款)。
                autofilled: autofilled,
                items: [
                  const UtenDropdownItem(value: 'WAREHOUSE', label: '送入仓库'),
                  UtenDropdownItem(
                    value: 'WORKSHOP',
                    enabled: canTransfer,
                    label: canTransfer ? '转下一道工序' : '转下一道工序(无同车间上层工单)',
                  ),
                ],
                onChanged: (next) {
                  if (next == null) return;
                  onDestinationChanged?.call(row, next);
                },
              ),
            );
          },
        );
      },
    ),
    EditableGridColumn<DailyGridRow>(
      key: 'directTransfer',
      label: '转给工单',
      width: 210,
      required: true,
      headerInfo:
          '本批产出投给同车间的哪个上层工单。只有一个候选时自动选中；'
          '上次投给过的父件产品会自动带入并标黄，改动即清除提醒；'
          '一次只投一个工单，要投多个就拆成多行。',
      textOf: (r) => r.directTransfer == null
          ? ''
          : _directTransferCellText(r.directTransfer!),
      listenableOf: (r) => r.directTransferNotifier,
      chromeWidth: UtenEditableGridCellSpec.dropdownChevronWidth,
      cellBuilder: (context, row) {
        if (row.isMaterialRow) return const SizedBox.shrink();
        return ValueListenableBuilder<String>(
          valueListenable: row.destinationNotifier,
          builder: (context, destination, _) {
            if (destination != 'WORKSHOP') {
              return Text(
                '—',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              );
            }
            return RequiredCellFrame(
              listenable: row.directTransferNotifier,
              isEmpty: () => row.directTransfer == null,
              child: ValueListenableBuilder<ProductionDirectTransferCandidate?>(
                valueListenable: row.directTransferNotifier,
                builder: (context, picked, _) => ValueListenableBuilder<bool>(
                  valueListenable: row.directTransferAutofilled,
                  builder: (context, autofilled, _) => UtenDropdownField(
                    dense: true,
                    value: picked?.demandId,
                    hintText: row.pendingDirectTransferDemandId == null
                        ? '选择上层工单'
                        : '原接收工单当前不可用，请刷新或重新选择',
                    // V595 记忆预填：黄框 + 警示图标提醒核对。
                    autofilled: autofilled && picked != null,
                    items: [
                      // 收起态与下拉项同一份文案（父件产品 · 工单号·还差多少）：
                      // UtenDropdownField 的格内值与浮层条目共用 label，两行条目
                      // 拼成一行省略号（2026-09-16 全站单行口径），textOf 量同款
                      // 文案保证列宽跟手。
                      for (final candidate in row.directTransferCandidates)
                        UtenDropdownItem(
                          value: candidate.demandId,
                          label: _directTransferCellText(candidate),
                        ),
                    ],
                    onChanged: (demandId) {
                      if (demandId == null) return;
                      onDirectTransferPicked?.call(
                        row,
                        row.directTransferCandidates.firstWhere(
                          (candidate) => candidate.demandId == demandId,
                        ),
                      );
                    },
                  ),
                ),
              ),
            );
          },
        );
      },
    ),
    // 2026-09-12 用户口径「新建生产日报不显示重量」：实际重量列撤出编辑表格
    //（行模型 weight 字段保留，回填/提交透传既有单不受影响；详情页只读回看不变）。
    EditableGridColumn<DailyGridRow>(
      key: 'planNo',
      label: '来源子任务',
      width: 240,
      textOf: (row) => row.isMaterialRow
          ? ''
          : (row.executionSegmentCode ?? row.planNo.text),
      // 格尾跳转图标计入量宽（2026-09-16）。
      chromeWidth: UtenEditableGridCellSpec.dropdownChevronWidth,
      cellBuilder: (context, row) => row.isMaterialRow
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
      textOf: (r) => r.isMaterialRow ? '' : r.remark.text,
      listenableOf: (r) => r.remark,
      cellBuilder: (context, row) => row.isMaterialRow
          ? const SizedBox.shrink()
          : TextField(
              controller: row.remark,
              decoration: const InputDecoration(isDense: true),
            ),
    ),
  ];
}

/// 数量文本：整数不带小数点，小数最多 4 位且不留尾零(与全站数量显示同口径)。
String _quantityText(double value) => value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value
          .toStringAsFixed(4)
          .replaceFirst(RegExp(r'0+$'), '')
          .replaceFirst(RegExp(r'\.$'), '');

/// 「转给工单」格的单元格文案：父件产品(收货品名+编号) · 工单号·还差多少。
/// 格内值、下拉条目与列宽测量(textOf)共用这一份，保证量宽与所见一致。
String _directTransferCellText(ProductionDirectTransferCandidate candidate) {
  final primary = candidate.receivingGoodsLabel.isEmpty
      ? candidate.label
      : candidate.receivingGoodsLabel;
  return candidate.secondaryLabel.isEmpty
      ? primary
      : '$primary · ${candidate.secondaryLabel}';
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
