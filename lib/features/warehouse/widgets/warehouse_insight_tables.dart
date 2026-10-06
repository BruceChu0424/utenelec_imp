// 库存分析四个分段的表格列定义 (ADR-135 §6.4, review/product.md §1.6)。
//
// - 呆滞与库龄: 货品 | 编号 | 颜色 | 库存数量 | 单位 | 库存重量 | 最后入库 | 最后消耗 | 呆滞天数 |
//   0-30天 … >365天 | 期初(无入库记录) | 近90天消耗 | 日均消耗 | 可用天数 | ABC (+ 库存金额, 仅服务端下发时);
// - 盘点建议: 货品 | 编号 | 颜色 | 仓库 | ABC | 上次盘点 | 距今 | 原因 | 优先级 | 库存数量 | 库存重量;
// - 称重异常: 日期 | 类型 | 货品 | 供应商或车间 | 单号 | 登记数量 | 称重折算 | 偏差 (个, %) | 依据可靠度
//   (折算数量与偏差由服务端按记录当时的单重算好);
//   「按往来方汇总」: 往来方 | 类别 | 次数 | 异常次数 | 平均偏差 | 差额重量;
// - 单重学习 (批量称样上线): 货品 | 编号 | 单位 | 当前单重 | 可靠度 | 依据 | 设计单重 | 差异 |
//   最近称重 | 抽样数量 | 抽样重量(g) | 保存。
// 重量一律千克进来, 按用户显示单位换算 (≈ 估算, 未称显示「未称」, 绝不显示成 0)。
import 'package:flutter/material.dart';

import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/inputs/uten_table_cell_action.dart';
import '../../../core/formatters/china_number_format.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/measurement/measurement_totals.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../../../shared/measurement/weight_predictor.dart';
import '../../../shared/measurement/weight_unit.dart';
import '../../../shared/measurement/widgets/weight_text.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/warehouse_insight.dart';

String _qty(double? v, {bool integer = false}) =>
    v == null ? '—' : formatWeighQty(v, integer: integer);

String _date(DateTime? d) => d == null ? '—' : ChinaDateTime.formatDate(d);

String _days(num? v) =>
    v == null ? '—' : formatWeighQty(v.toDouble(), integer: true);

String _pct(double? v) => v == null ? '—' : formatSignedPct(v);

/// 呆滞与库龄列。[showAmount] = 服务端下发了金额 (持 goods:cost:view)。
List<MasterColumnDef<InsightHealthRow>> insightHealthColumns({
  required WeightDisplay display,
  required bool showAmount,
}) => [
  MasterColumnDef(
    key: 'name',
    label: '货品',
    width: 200,
    value: (r) => r.name ?? '—',
  ),
  MasterColumnDef(
    key: 'code',
    label: '编号',
    width: 130,
    value: (r) => r.code ?? '—',
  ),
  MasterColumnDef(
    key: 'colorName',
    label: '颜色',
    width: 90,
    value: (r) => r.colorName ?? '—',
  ),
  MasterColumnDef(
    key: 'qty',
    label: '库存数量',
    width: 110,
    type: 'number',
    sortable: true,
    value: (r) => _qty(r.qty),
    exactValueOf: (r) => r.qty?.toString(),
  ),
  MasterColumnDef(
    key: 'unitName',
    label: '单位',
    width: 70,
    value: (r) => r.unitName ?? '—',
  ),
  MasterColumnDef(
    key: 'weightKg',
    label: '库存重量',
    width: 120,
    type: 'weight',
    sortable: true,
    exactValueOf: (r) => r.weightKg?.toString(),
    info: '≈ = 含估算重量; 未称 = 有没称过的库存, 不当 0 算',
    value: (r) => formatWeightValue(
      r.weightKg,
      display: display,
      estimated: r.weightEstimated,
    ),
    cellBuilder: (_, r) => WeightText(
      kg: r.weightKg,
      estimated: r.weightEstimated,
      display: display,
    ),
  ),
  MasterColumnDef(
    key: 'lastInAt',
    label: '最后入库',
    width: 110,
    type: 'date',
    sortable: true,
    value: (r) => _date(r.lastInAt),
  ),
  MasterColumnDef(
    key: 'lastOutAt',
    label: '最后消耗',
    width: 110,
    type: 'date',
    sortable: true,
    value: (r) => _date(r.lastOutAt),
  ),
  MasterColumnDef(
    key: 'idleDays',
    label: '呆滞天数',
    width: 100,
    type: 'number',
    sortable: true,
    info: '距最后一次出入库的天数',
    value: (r) => _days(r.idleDays),
    exactValueOf: (r) => r.idleDays?.toString(),
  ),
  MasterColumnDef(
    key: 'age0_30',
    label: '0-30天',
    width: 100,
    type: 'number',
    info: '按先进先出把当前库存分到各次入库上, 入库距今 0-30 天的数量',
    value: (r) => _qty(r.age0to30),
    exactValueOf: (r) => r.age0to30?.toString(),
  ),
  MasterColumnDef(
    key: 'age31_90',
    label: '31-90天',
    width: 100,
    type: 'number',
    value: (r) => _qty(r.age31to90),
    exactValueOf: (r) => r.age31to90?.toString(),
  ),
  MasterColumnDef(
    key: 'age91_180',
    label: '91-180天',
    width: 100,
    type: 'number',
    value: (r) => _qty(r.age91to180),
    exactValueOf: (r) => r.age91to180?.toString(),
  ),
  MasterColumnDef(
    key: 'age181_365',
    label: '181-365天',
    width: 105,
    type: 'number',
    value: (r) => _qty(r.age181to365),
    exactValueOf: (r) => r.age181to365?.toString(),
  ),
  MasterColumnDef(
    key: 'ageOver365',
    label: '超365天',
    width: 100,
    type: 'number',
    sortable: true,
    value: (r) => _qty(r.ageOver365),
    exactValueOf: (r) => r.ageOver365?.toString(),
  ),
  MasterColumnDef(
    key: 'ageUnknown',
    label: '期初(无入库记录)',
    width: 140,
    type: 'number',
    info: '找不到入库记录的数量 (系统上线前的结存等), 库龄未知',
    value: (r) => _qty(r.ageUnknown),
    exactValueOf: (r) => r.ageUnknown?.toString(),
  ),
  MasterColumnDef(
    key: 'out90',
    label: '近90天消耗',
    width: 110,
    type: 'number',
    sortable: true,
    info: '销售/领料/委外发料等真实消耗 (调拨不算)',
    value: (r) => _qty(r.out90),
    exactValueOf: (r) => r.out90?.toString(),
  ),
  MasterColumnDef(
    key: 'avgDailyOut90',
    label: '日均消耗',
    width: 100,
    type: 'number',
    sortable: true,
    value: (r) => r.avgDailyOut90 == null
        ? '—'
        : formatWeighQty(r.avgDailyOut90!, integer: false),
    exactValueOf: (r) => r.avgDailyOut90?.toString(),
  ),
  MasterColumnDef(
    key: 'daysOfCover',
    label: '可用天数',
    width: 100,
    type: 'number',
    sortable: true,
    info: '按近 90 天日均消耗, 现有库存大约还能用多少天',
    value: (r) => r.daysOfCover == null
        ? '—'
        : formatWeighQty(r.daysOfCover!, integer: true),
    exactValueOf: (r) => r.daysOfCover?.toString(),
  ),
  MasterColumnDef(
    key: 'abc',
    label: 'ABC',
    width: 80,
    info: '按近 90 天出库次数: A = 最常动的一批 (累计 80%), B = 到 95%, C = 其余',
    value: (r) => insightAbcLabel(r.abc),
  ),
  if (showAmount)
    MasterColumnDef(
      key: 'amountLocal',
      label: '库存金额',
      width: 120,
      type: 'money',
      aiSensitive: true,
      sortable: true,
      exactValueOf: (r) => r.costMasked ? null : r.amountLocalText,
      value: (r) =>
          r.amountLocal == null ? '—' : formatChinaNumber(r.amountLocal!),
    ),
];

/// 盘点建议列 (可勾选, 按仓生成盘点单; 一行 = 一条盘点明细: 仓库 x 货品 x 颜色)。
List<MasterColumnDef<InsightCycleCountRow>> insightCycleCountColumns({
  required WeightDisplay display,
}) => [
  MasterColumnDef(
    key: 'name',
    label: '货品',
    width: 200,
    value: (r) => r.name ?? '—',
  ),
  MasterColumnDef(
    key: 'code',
    label: '编号',
    width: 130,
    value: (r) => r.code ?? '—',
  ),
  MasterColumnDef(
    key: 'colorName',
    label: '颜色',
    width: 90,
    value: (r) => r.colorName ?? '—',
  ),
  MasterColumnDef(
    key: 'warehouseName',
    label: '仓库',
    width: 130,
    value: (r) => r.warehouseName ?? '—',
  ),
  MasterColumnDef(
    key: 'abc',
    label: 'ABC',
    width: 80,
    value: (r) => insightAbcLabel(r.abc),
  ),
  MasterColumnDef(
    key: 'lastCountedOn',
    label: '上次盘点',
    width: 110,
    type: 'date',
    info: '该仓该颜色最近一张已审核盘点单的日期; 没盘过按第一次出入库起算',
    value: (r) => r.lastCountedOn == null ? '没盘过' : _date(r.lastCountedOn),
  ),
  MasterColumnDef(
    key: 'daysSince',
    label: '距今(天)',
    width: 90,
    type: 'number',
    value: (r) => _days(r.daysSince),
    exactValueOf: (r) => r.daysSince?.toString(),
  ),
  MasterColumnDef(
    key: 'reasons',
    label: '原因',
    width: 220,
    info: '到期 = 超过盘点周期 (A 30 天, B 90 天, 其余 180 天); 近期尾差 = 近 90 天出现过重量尾差调整',
    value: (r) => r.reasonText,
  ),
  MasterColumnDef(
    key: 'score',
    label: '优先级',
    width: 80,
    value: (r) => r.priorityLabel,
  ),
  MasterColumnDef(
    key: 'qty',
    label: '库存数量',
    width: 110,
    type: 'number',
    value: (r) =>
        r.unitName == null ? _qty(r.qty) : '${_qty(r.qty)} ${r.unitName}',
    exactValueOf: (r) => r.qty?.toString(),
  ),
  MasterColumnDef(
    key: 'weightKg',
    label: '库存重量',
    width: 120,
    type: 'weight',
    exactValueOf: (r) => r.weightKg?.toString(),
    value: (r) => formatWeightValue(
      r.weightKg,
      display: display,
      estimated: r.weightEstimated,
    ),
    cellBuilder: (_, r) => WeightText(
      kg: r.weightKg,
      estimated: r.weightEstimated,
      display: display,
    ),
  ),
];

/// 称重异常列。[billCell] 画单号 (有查看权限时是链接)。
List<MasterColumnDef<InsightWeightAlertRow>> insightWeightAlertColumns({
  required Widget Function(BuildContext context, InsightWeightAlertRow row)
  billCell,
}) => [
  MasterColumnDef(
    key: 'observedAt',
    label: '日期',
    width: 110,
    type: 'date',
    value: (r) => _date(r.observedAt),
  ),
  MasterColumnDef(
    key: 'type',
    label: '类型',
    width: 130,
    value: (r) => r.typeLabel,
    cellBuilder: (context, r) {
      final color = weightAlertColor(Theme.of(context), r.alertLevel);
      return Text(
        r.typeLabel,
        style: color == null
            ? null
            : TextStyle(color: color, fontWeight: FontWeight.w600),
      );
    },
  ),
  // 2026-09-29 用户口径：名称列只放名称，编号/颜色各占一列。
  MasterColumnDef(
    key: 'name',
    label: '货品',
    width: 200,
    value: (r) => r.name ?? '—',
  ),
  MasterColumnDef(
    key: 'goodsCode',
    label: '编号',
    width: 110,
    value: (r) => UtenGoodsAttributeCell.text(r.code),
    cellBuilder: (context, r) => UtenGoodsAttributeCell(r.code),
  ),
  MasterColumnDef(
    key: 'colorName',
    label: '颜色',
    width: 84,
    value: (r) => UtenGoodsAttributeCell.text(r.colorName),
    cellBuilder: (context, r) => UtenGoodsAttributeCell(r.colorName),
  ),
  MasterColumnDef(
    key: 'counterpart',
    label: '供应商或车间',
    width: 150,
    value: (r) => r.counterpartText ?? '—',
  ),
  MasterColumnDef(
    key: 'billNo',
    label: '单号',
    width: 150,
    value: (r) => r.billNo ?? '—',
    cellBuilder: billCell,
  ),
  MasterColumnDef(
    key: 'qtyBase',
    label: '登记数量',
    width: 110,
    type: 'number',
    value: (r) => r.isRegimeChange
        ? '—'
        : _withUnit(_qty(r.qtyBase, integer: r.integerQty), r),
    exactValueOf: (r) => r.isRegimeChange ? null : r.qtyBase?.toString(),
  ),
  MasterColumnDef(
    key: 'estimatedQty',
    label: '称重折算',
    width: 130,
    type: 'number',
    info: '实称重量 ÷ 当时的单重',
    exactValueOf: (r) => r.isRegimeChange ? null : r.estimatedQty?.toString(),
    value: (r) {
      final est = r.estimatedQty;
      if (r.isRegimeChange || est == null) return '—';
      return '≈${_withUnit(_qty(est, integer: r.integerQty), r)}';
    },
  ),
  MasterColumnDef(
    key: 'deviation',
    label: '偏差',
    width: 150,
    type: 'number',
    exactValueOf: (r) => r.isRegimeChange ? null : r.deviationQty?.toString(),
    value: (r) {
      final diff = r.deviationQty;
      final pct = r.deviationPct;
      if (r.isRegimeChange) return '—';
      final parts = [
        if (diff != null)
          '${diff > 0 ? '多' : '少'}约${_withUnit(_qty(diff.abs(), integer: r.integerQty), r)}',
        if (pct != null) '(${_pct(pct)})',
      ];
      return parts.isEmpty ? '—' : parts.join(' ');
    },
  ),
  MasterColumnDef(
    key: 'tierUsed',
    label: '依据可靠度',
    width: 100,
    value: (r) => r.tierUsed?.label ?? '—',
    // 2026-09-27 用户口径「格内胶囊改单元格背景色」：档位色铺整格。
    cellColor: (context, r) => r.tierUsed == null
        ? null
        : udenStatusBadgeCellColor(context, weightTierBadgeType(r.tierUsed!)),
  ),
];

String _withUnit(String qty, InsightWeightAlertRow r) {
  final unit = r.unitName?.trim() ?? '';
  if (unit.isEmpty || qty == '—') return qty;
  return RegExp(r'^[A-Za-z]').hasMatch(unit) ? '$qty $unit' : '$qty$unit';
}

/// 「按往来方汇总」列 (供应商来料少数 + 车间领料超发)。
List<MasterColumnDef<InsightCounterpartSummary>> insightCounterpartColumns({
  required WeightDisplay display,
}) => [
  MasterColumnDef(
    key: 'partyName',
    label: '往来方',
    width: 180,
    value: (s) => s.partyName ?? '—',
  ),
  MasterColumnDef(
    key: 'kind',
    label: '类别',
    width: 110,
    filterFromRows: true,
    value: (s) => s.isSupplier ? '供应商来料' : '车间领料',
  ),
  MasterColumnDef(
    key: 'events',
    label: '次数',
    width: 90,
    type: 'number',
    info: '供应商 = 到货称重次数; 车间 = 领料称重次数',
    value: (s) => _days(s.events),
    exactValueOf: (s) => s.events?.toString(),
  ),
  MasterColumnDef(
    key: 'flagged',
    label: '异常次数',
    width: 100,
    type: 'number',
    info: '供应商 = 来料少数的次数; 车间 = 领料超发的次数',
    value: (s) => _days(s.flagged),
    exactValueOf: (s) => s.flagged?.toString(),
  ),
  MasterColumnDef(
    key: 'avgPct',
    label: '平均偏差',
    width: 100,
    type: 'number',
    exactValueOf: (s) => s.avgPct?.abs().toString(),
    value: (s) => s.avgPct == null
        ? '—'
        : '${s.isSupplier ? '少' : '多'} '
              '${formatMeasurementValue(s.avgPct!.abs(), scale: 1)}%',
  ),
  MasterColumnDef(
    key: 'kg',
    label: '差额重量',
    width: 120,
    type: 'weight',
    exactValueOf: (s) => s.kg?.abs().toString(),
    info: '供应商 = 少了的重量; 车间 = 多发的重量',
    value: (s) =>
        s.kg == null ? '—' : formatWeightValue(s.kg!.abs(), display: display),
  ),
];

/// 单重学习一行的抽样输入 (页面持有, 跨翻页保留; 保存成功后清空)。
class InsightSampleDraft {
  final qty = TextEditingController();
  final weight = TextEditingController();
  bool saving = false;
  bool saved = false;
  String? error;

  /// 本行第几次保存 (进幂等键: 失败重试同键, 保存成功后换键)。
  int attempt = 0;

  void dispose() {
    qty.dispose();
    weight.dispose();
  }
}

/// 单重学习 (批量称样上线) 列。
List<MasterColumnDef<InsightLearningRow>> insightLearningColumns({
  required WeightUnit sampleUnit,
  required InsightSampleDraft Function(String goodsId) draftOf,
  required bool canSample,
  required ValueChanged<InsightLearningRow> onSave,
  ValueChanged<InsightLearningRow>? onEdited,
}) => [
  MasterColumnDef(
    key: 'name',
    label: '货品',
    width: 200,
    value: (r) => r.name ?? '—',
  ),
  MasterColumnDef(
    key: 'code',
    label: '编号',
    width: 130,
    value: (r) => r.code ?? '—',
  ),
  MasterColumnDef(
    key: 'unitName',
    label: '单位',
    width: 70,
    value: (r) => r.unitName ?? '—',
  ),
  MasterColumnDef(
    key: 'unitWeightKg',
    label: '当前单重',
    width: 120,
    type: 'number',
    value: (r) => formatUnitWeight(r.unitWeightKg),
    exactValueOf: (r) => r.unitWeightKg?.toString(),
  ),
  MasterColumnDef(
    key: 'tier',
    label: '可靠度',
    width: 90,
    value: (r) => r.tier?.label ?? WeightTier.red.label,
    // 2026-09-27 用户口径「格内胶囊改单元格背景色」：档位色铺整格。
    cellColor: (context, r) => udenStatusBadgeCellColor(
      context,
      weightTierBadgeType(r.tier ?? WeightTier.red),
    ),
  ),
  MasterColumnDef(
    key: 'basis',
    label: '依据',
    width: 190,
    value: (r) => r.basisText,
  ),
  MasterColumnDef(
    key: 'masterUnitWeightKg',
    label: '设计单重',
    width: 110,
    type: 'number',
    info: '货品资料里填的单重 (只作参考, 学到的单重不会回写货品资料)',
    value: (r) => formatUnitWeight(r.masterUnitWeightKg),
    exactValueOf: (r) => r.masterUnitWeightKg?.toString(),
  ),
  MasterColumnDef(
    key: 'masterDiffPct',
    label: '与设计差异',
    width: 110,
    type: 'number',
    value: (r) => _pct(r.masterDiffPct),
    exactValueOf: (r) => r.masterDiffPct?.toString(),
  ),
  MasterColumnDef(
    key: 'lastObservedAt',
    label: '最近称重',
    width: 110,
    type: 'date',
    value: (r) => _date(r.lastObservedAt),
  ),
  MasterColumnDef(
    key: 'sampleQty',
    label: '抽样数量',
    width: 120,
    type: 'number',
    exactValueOf: (r) => draftOf(r.goodsId).qty.text,
    exactListenableOf: (r) => draftOf(r.goodsId).qty,
    info: '数出这么多件放上秤 (建议数量见占位)',
    value: (r) => draftOf(r.goodsId).qty.text,
    cellBuilderHandlesSemantics: true,
    cellBuilder: (context, r) {
      final draft = draftOf(r.goodsId);
      return Semantics(
        textField: true,
        label: '${r.name ?? r.code ?? ''} 抽样数量',
        child: TextField(
          key: ValueKey('insight-sample-qty-${r.goodsId}'),
          controller: draft.qty,
          enabled: canSample && !draft.saving && r.learningEnabled,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textAlign: TextAlign.right,
          onChanged: (_) => onEdited?.call(r),
          decoration: InputDecoration(
            isDense: true,
            hintText: r.suggestedSampleSize == null
                ? '件数'
                : '建议 ${r.suggestedSampleSize}',
          ),
        ),
      );
    },
  ),
  MasterColumnDef(
    key: 'sampleWeight',
    label: '抽样重量(${sampleUnit.symbol})',
    width: 130,
    type: 'number',
    exactValueOf: (r) {
      final input = parseWithSuffix(draftOf(r.goodsId).weight.text, sampleUnit);
      return input == null || input.value <= 0
          ? null
          : financeExactMultiplyTexts([
              input.numberText,
              input.unit.kgPerUnit.toString(),
            ]);
    },
    exactListenableOf: (r) => draftOf(r.goodsId).weight,
    info: '抽样那几件的净重 (扣掉盘/袋); 也可以直接输 46.2g、0.05kg',
    value: (r) => draftOf(r.goodsId).weight.text,
    cellBuilderHandlesSemantics: true,
    cellBuilder: (context, r) {
      final draft = draftOf(r.goodsId);
      return Semantics(
        textField: true,
        label: '${r.name ?? r.code ?? ''} 抽样重量',
        child: TextField(
          key: ValueKey('insight-sample-weight-${r.goodsId}'),
          controller: draft.weight,
          enabled: canSample && !draft.saving && r.learningEnabled,
          textAlign: TextAlign.right,
          onChanged: (_) => onEdited?.call(r),
          onSubmitted: (_) => onSave(r),
          // 校验提示收进输入框内的提示图标 (全站输入框统一规范), 不另占一行。
          decoration: UtenInputDecoration(
            InputDecoration(
              isDense: true,
              hintText: sampleUnit.symbol,
              error: utenFieldError(draft.error),
            ),
          ),
        ),
      );
    },
  ),
  MasterColumnDef(
    key: 'save',
    label: '保存',
    width: 110,
    value: (r) => draftOf(r.goodsId).saved ? '已保存' : '',
    cellBuilderHandlesSemantics: true,
    cellBuilder: (context, r) {
      final draft = draftOf(r.goodsId);
      final tooltip = !r.learningEnabled
          ? '本货品已关闭单重学习'
          : (canSample ? '保存这次抽样, 立即重算单重' : '没有称样权限');
      // 2026-10-06 行高统一口径：保存动作用单行文字动作（原 UtenButton 会把
      // 抽样行撑高）；保存中文案切换替代转圈，已保存勾图标收敛到 16。
      return Tooltip(
        message: tooltip,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            UtenTableCellAction(
              key: ValueKey('insight-sample-save-${r.goodsId}'),
              label: draft.saving ? '保存中…' : '保存',
              onPressed: canSample && r.learningEnabled && !draft.saving
                  ? () => onSave(r)
                  : null,
            ),
            if (draft.saved)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(
                  Icons.check_circle,
                  key: ValueKey('insight-sample-saved-${r.goodsId}'),
                  size: 16,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
          ],
        ),
      );
    },
  ),
];
