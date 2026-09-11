import 'package:flutter/widgets.dart';

import '../../../shared/measurement/measurement_totals.dart';
import '../../../shared/presentation/workflow_field_guidance.dart';
import '../../warehouse/repositories/procurement_inspection_repository.dart';

String inspectionQuantityTotalText(
  BuildContext context,
  Iterable<(ProcurementInspectionItem, double)> quantities,
) {
  final rows = quantities.toList(growable: false);
  final known = rows.where((row) => row.$1.baseUnitId?.isNotEmpty == true);
  final unknownCount = rows.length - known.length;
  return [
    if (known.isNotEmpty)
      measurementTotalsText(
        known.map(
          (row) => MeasuredAmount(
            value: row.$2,
            unitId: row.$1.baseUnitId,
            unitName: inspectionQuantityUnit(context, row.$1),
          ),
        ),
      ),
    if (unknownCount > 0)
      '$unknownCount 行${workflowFieldText(context).workflowUnitUnknown}',
  ].join(' · ');
}

String inspectionQuantityUnit(
  BuildContext context,
  ProcurementInspectionItem item,
) => item.baseUnitName?.trim().isNotEmpty == true
    ? item.baseUnitName!
    : workflowFieldText(context).workflowUnitUnknown;

/// 「验收单位」列的显示文本：单位 + **本行的换算事实**。
///
/// 2026-09-11 把合格/不合格数量的 ⓘ 收到表头后，逐行不同的换算倍率
/// （「原单 1 箱 = 24 个」）就没地方待了——而它正是防止把箱数当个数填进去的
/// 那条关键信息。放进本列的正文里：不占输入框的宽，也不用点开才看得见。
String inspectionQuantityUnitCell(
  BuildContext context,
  ProcurementInspectionItem item,
) {
  final unit = inspectionQuantityUnit(context, item);
  final rate = item.unitRate;
  final source = item.sourceUnitName?.trim();
  if (source == null ||
      source.isEmpty ||
      rate == null ||
      rate <= 0 ||
      source == item.baseUnitName?.trim()) {
    return unit;
  }
  return '$unit（原单1$source = ${formatMeasurementValue(rate, scale: 6)}$unit）';
}

/// 合格/不合格数量的**列头**说明（2026-09-11 用户要求：提示 ⓘ 统一挂表头，
/// 行内只留报错）。只放整列都成立的录入口径；逐行不同的单位换算倍率不放这里
/// （表里本就有单位列，且行内再塞 ⓘ 会把输入框挤窄）。
String inspectionQuantityColumnHint(
  BuildContext context, {
  required bool passed,
}) {
  final text = workflowFieldText(context);
  return passed ? text.workflowIqcPassHint : text.workflowIqcFailHint;
}

/// IQC API quantities are already converted. Never label them with the order's
/// packaging unit or convert them a second time while submitting a report.
String inspectionQuantityHint(
  BuildContext context,
  ProcurementInspectionItem item, {
  required bool passed,
}) {
  final text = workflowFieldText(context);
  final rate = item.unitRate;
  final basis =
      item.baseUnitName?.trim().isNotEmpty == true &&
          item.sourceUnitName?.trim().isNotEmpty == true &&
          rate != null &&
          rate > 0
      ? text.workflowIqcUnitHint(
          item.sourceUnitName!,
          formatMeasurementValue(rate, scale: 6),
          item.baseUnitName!,
        )
      : text.workflowUnitUnknown;
  return '$basis ${passed ? text.workflowIqcPassHint : text.workflowIqcFailHint}';
}
