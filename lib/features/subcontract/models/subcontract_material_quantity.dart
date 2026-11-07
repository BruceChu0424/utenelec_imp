import '../../../core/formatters/exact_number_text.dart';
import '../../../shared/formatters/quantity_display.dart';

String formatSubcontractMaterialQtyBreakdown({
  String? baseQty,
  String? lossQty,
  required String? totalQty,
  required String? unitName,
}) {
  final base = exactNumberDisplay(baseQty);
  final loss = exactNumberDisplay(lossQty);
  if (base == null || loss == null || loss == '0') {
    return formatExactQtyWithUnit(totalQty, unitName);
  }
  return '$base + $loss ${unitName?.trim() ?? ''}'.trimRight();
}
