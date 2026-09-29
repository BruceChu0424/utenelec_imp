// BOM 边「本次按哪个用量算」的人话说明(ADR-129 §2.5、§2.11)。
//
// 为什么按设计使用数量算(原因代码 → 人话)只有一个来源：组装信息页的
// [bomDesignReasonText](多语言)，这里不另写一份；界面只显示人话，不直接显示代码。
// 数量格式与组装信息页同用 [formatBomQty](6 位去尾零)，不良率同用 [formatBomDefectRate]。
import '../../../core/l10n/gen/app_localizations.dart';
import '../../basic_data/models/goods_bom_item.dart'
    show bomDesignReasonText, formatBomDefectRate, formatBomQty;
import '../models/production_material_analysis.dart';

/// 一个 BOM 用量对应多少父件：按每件 / 按包装(每 N 件) / 固定批耗(每批)。
String bomUsagePerLabel(String? consumptionBasis, double? basisOutputQty) =>
    switch (consumptionBasis) {
      'PER_PACKAGE' when basisOutputQty != null && basisOutputQty != 1 =>
        '每 ${formatBomQty(basisOutputQty)} 件',
      'FIXED_BATCH' => '每批',
      _ => '每件',
    };

/// 一条 BOM 边本次按哪个用量算，例如
/// 「每件按真实使用数量 0.105 计算(12 批累计，设计 0.1，不良率 3.25%)」、
/// 「每件按设计使用数量 0.1 计算：还没有已完工且核清余料的生产数据」。
///
/// [usedQty] 是计算实际采用的用量；[perLabel] 见 [bomUsagePerLabel]。
/// [defectRate] 只在按真实使用数量且大于 0 时列出(只作说明，不参与用量计算)。
String formatBomUsageBasis(
  AppLocalizations l10n, {
  required bool usesActual,
  required double usedQty,
  double? designQty,
  double? actualQty,
  String? reason,
  int? sampleCount,
  double? defectRate,
  String perLabel = '每件',
}) {
  if (usesActual) {
    final facts = [
      if (sampleCount != null && sampleCount > 0) '$sampleCount 批累计',
      if (designQty != null) '设计 ${formatBomQty(designQty)}',
      if (defectRate != null && defectRate > 0)
        '不良率 ${formatBomDefectRate(defectRate)}',
    ];
    return '$perLabel按真实使用数量 ${formatBomQty(usedQty)} 计算'
        '${facts.isEmpty ? '' : '(${facts.join('，')})'}';
  }
  return '$perLabel按设计使用数量 ${formatBomQty(usedQty)} 计算：'
      '${bomDesignReasonText(l10n, reason)}'
      '${actualQty == null ? '' : '(真实使用数量 ${formatBomQty(actualQty)})'}';
}

/// 物料分析节点锁定的用量说明；顶层供给行与没有 BOM 边的行返回 null。
String? materialAnalysisUsageBasisText(
  AppLocalizations l10n,
  ProductionMaterialAnalysisMaterial material,
) {
  final used = material.bomQty;
  if (used == null || material.isRootSupply) return null;
  return formatBomUsageBasis(
    l10n,
    usesActual: material.usageBasis == 'ACTUAL',
    usedQty: used,
    designQty: material.designBomQty,
    actualQty: material.actualBomQty,
    reason: material.usageReason,
    sampleCount: material.usageSampleCount,
    defectRate: material.usageDefectRate,
    perLabel: bomUsagePerLabel(
      material.consumptionBasis,
      material.basisOutputQty,
    ),
  );
}
