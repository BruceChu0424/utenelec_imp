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
