// 采集表格表尾的重量合计项 (ADR-135 §6.2):
// 「明细 12 行 · 本次实收 60,000 个 · 实称 125.3 kg (未称 3 行) · 称重偏差 2 行」。
//
// 本文件只拼重量那两项 (实称 / 称重偏差); 明细行数与数量合计仍由各页用
// UtenTotalEntry('明细', ...) 与 utenQuantityTotalEntry 构造, 同一条 UtenTotalsSummaryBar 渲染。
// 编辑中的采集表格合计在客户端算 (尚未保存的输入), 服务端分页表格的重量合计走
// report_total.dart 的 'weight' 类型 (服务端算)。
import '../../../components/data_display/uten_totals_summary_bar.dart';
import '../weight_unit.dart';

/// 一张采集表格的重量汇总。
class WeightTotalsSummary {
  const WeightTotalsSummary({
    required this.rows,
    required this.weighedRows,
    required this.totalKg,
    this.deviationRows = 0,
  });

  /// 逐行千克值 (null = 没称; 0 视为没称) 汇总。
  factory WeightTotalsSummary.of(
    Iterable<double?> weightsKg, {
    int deviationRows = 0,
  }) {
    var rows = 0;
    var weighed = 0;
    var total = 0.0;
    for (final kg in weightsKg) {
      rows++;
      if (kg == null || !kg.isFinite || kg <= 0) continue;
      weighed++;
      total += kg;
    }
    return WeightTotalsSummary(
      rows: rows,
      weighedRows: weighed,
      totalKg: total,
      deviationRows: deviationRows,
    );
  }

  final int rows;
  final int weighedRows;
  final double totalKg;

  /// 称重偏差 (WARN/ALERT) 的行数。
  final int deviationRows;

  int get unweighedRows => rows - weighedRows;
}

/// 重量合计项: [label] 如「实称」→「125.3 kg (未称 3 行)」; 一行都没称时整项隐藏 (值为空)。
UtenTotalEntry weightTotalEntry(
  WeightTotalsSummary summary, {
  String label = '实称',
  WeightDisplay display = WeightDisplay.auto,
}) {
  if (summary.weighedRows == 0) return UtenTotalEntry(label, '');
  final total = formatWeight(roundKgLine(summary.totalKg), display: display);
  final unweighed = summary.unweighedRows;
  return UtenTotalEntry(
    label,
    unweighed > 0 ? '$total (未称 $unweighed 行)' : total,
  );
}

/// 称重偏差项 (标红); 没有偏差行时整项隐藏。
UtenTotalEntry weightDeviationEntry(
  WeightTotalsSummary summary, {
  String label = '称重偏差',
}) => UtenTotalEntry(
  label,
  summary.deviationRows > 0 ? '${summary.deviationRows} 行' : '',
  danger: true,
);

/// 表尾重量两项 (实称 + 称重偏差), 接在明细/数量合计项之后。
List<UtenTotalEntry> weightTotalEntries(
  WeightTotalsSummary summary, {
  String label = '实称',
  WeightDisplay display = WeightDisplay.auto,
}) => [
  weightTotalEntry(summary, label: label, display: display),
  weightDeviationEntry(summary),
];
