// 生产日报明细可编辑表的行模型 + 列定义（UtenEditableGrid 用）。
//
// 日报记录非金额生产计量事实：完工申报量及可选实际总重量。
// 客户端单价/金额不是计件工资权威，已从操作界面移除。
// DailyGridRow：货品(选择)/完工申报量/实际重量；颜色/单位选货品后自动回填（只读）；
// 精确来源子任务 + 完结标记 + 备注。
import 'package:flutter/material.dart';

import '../../../components/layout/uten_editable_grid.dart';
import '../../../shared/providers/master_name_provider.dart';

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
  bool legacyManual = false;

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
    super.dispose();
  }
}

/// 生产日报明细列：货品（点选）/ 颜色（只读）/ 单位（只读）/ 完工申报量 / 实际重量 /
/// 关联计划号 / 备注。[onPickGoods] 由编辑页提供；[colorEntries]/[unitEntries] 由编辑页注入。
List<EditableGridColumn<DailyGridRow>> dailyGridColumns({
  required Future<void> Function(DailyGridRow row) onPickGoods,
  required Future<void> Function(DailyGridRow row) onPickSource,
  required void Function(DailyGridRow row) onClearSource,
  required Map<String, String> colorEntries,
  required Map<String, String> unitEntries,
}) {
  return [
    EditableGridColumn<DailyGridRow>(
      key: 'goods',
      label: '货品',
      width: 220,
      required: true,
      textOf: (r) => r.goods?.name ?? '',
      listenableOf: (r) => r.goodsNotifier,
      cellBuilder: (context, row) => RequiredCellFrame(
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
                    builder: (context, g, _) => Text(
                      g?.name ?? '点击选择',
                      style: TextStyle(
                        color: g == null
                            ? Theme.of(context).colorScheme.onSurfaceVariant
                            : Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ),
                ),
                const Icon(Icons.search_rounded, size: 16),
              ],
            ),
          ),
        ),
      ),
    ),
    EditableGridColumn<DailyGridRow>(
      key: 'color',
      label: '颜色',
      width: 130,
      textOf: (r) => colorEntries[r.colorId ?? ''] ?? '',
      listenableOf: (r) => r.colorIdNotifier,
      cellBuilder: (context, row) =>
          _readOnlyMasterCell(context, row.colorIdNotifier, colorEntries),
    ),
    EditableGridColumn<DailyGridRow>(
      key: 'unit',
      label: '单位',
      width: 110,
      textOf: (r) => unitEntries[r.unitId ?? ''] ?? '',
      listenableOf: (r) => r.unitIdNotifier,
      cellBuilder: (context, row) =>
          _readOnlyMasterCell(context, row.unitIdNotifier, unitEntries),
    ),
    EditableGridColumn<DailyGridRow>(
      key: 'qty',
      label: '完工申报量',
      width: 118,
      numeric: true,
      required: true,
      cellBuilder: (context, row) => RequiredCellFrame(
        listenable: row.qty,
        isEmpty: () => (double.tryParse(row.qty.text.trim()) ?? 0) <= 0,
        child: TextField(
          controller: row.qty,
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(isDense: true, hintText: '0'),
        ),
      ),
    ),
    EditableGridColumn<DailyGridRow>(
      key: 'weight',
      label: '实际重量',
      width: 112,
      numeric: true,
      cellBuilder: (context, row) => TextField(
        controller: row.weight,
        textAlign: TextAlign.right,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(isDense: true, hintText: '可选'),
      ),
    ),
    EditableGridColumn<DailyGridRow>(
      key: 'planNo',
      label: '来源子任务',
      width: 190,
      cellBuilder: (context, row) => InkWell(
        onTap: () => onPickSource(row),
        child: InputDecorator(
          decoration: const InputDecoration(isDense: true),
          child: Row(
            children: [
              Expanded(
                child: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: row.planNo,
                  builder: (_, value, _) => Text(
                    value.text.isEmpty
                        ? '点击选择'
                        : '${row.recoveryLabel == null ? '' : '[${row.recoveryLabel}] '}'
                              '${value.text}'
                              '${row.fqcSourceReportNo == null ? '' : ' · 原报工 ${row.fqcSourceReportNo}'}'
                              '${row.salesOrderNo == null ? '' : ' · ${row.salesOrderNo}'}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: value.text.isEmpty
                          ? Theme.of(context).colorScheme.onSurfaceVariant
                          : null,
                    ),
                  ),
                ),
              ),
              if (row.hasLinkedSource || row.hasSourceSnapshot)
                IconButton(
                  tooltip: '清除来源',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onClearSource(row),
                  icon: const Icon(Icons.close_rounded, size: 16),
                )
              else
                const Icon(Icons.search_rounded, size: 16),
            ],
          ),
        ),
      ),
    ),
    EditableGridColumn<DailyGridRow>(
      key: 'isFinal',
      label: '完结',
      width: 56,
      cellBuilder: (context, row) => ValueListenableBuilder<bool>(
        valueListenable: row.finalNotifier,
        builder: (_, v, _) => Tooltip(
          message: row.isFqcRecovery
              ? '返工/补产恢复报工不能作为原计划完结行'
              : '完结后按品质最终结果处理不足数量',
          child: Checkbox(
            value: row.isFqcRecovery ? false : v,
            onChanged: row.isFqcRecovery
                ? null
                : (nv) => row.isFinal = nv ?? false,
          ),
        ),
      ),
    ),
    EditableGridColumn<DailyGridRow>(
      key: 'remark',
      label: '备注',
      width: 180,
      textOf: (r) => r.remark.text,
      listenableOf: (r) => r.remark,
      cellBuilder: (context, row) => TextField(
        controller: row.remark,
        decoration: const InputDecoration(isDense: true),
      ),
    ),
  ];
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
