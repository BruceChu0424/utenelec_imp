import '../../../core/network/api_exception.dart';
import 'warehouse_quality_result.dart';

/// Null is the existing whole-document review; a physical-row selection is exact.
List<String>? warehouseQualityInspectionSelection(
  List<WarehouseQualityResultTask> tasks,
) {
  if (tasks.every((task) => task.line == null)) return null;
  if (tasks.any((task) => task.line?.itemId?.isNotEmpty != true)) {
    throw ApiException('CONFLICT', '所选品质放行明细已变化，请刷新后重新选择');
  }
  return tasks.map((task) => task.line!.itemId!).toSet().toList()..sort();
}

void validateWarehouseQualityInspectionSelection(
  Iterable<WarehouseQualityResultDetail> details,
  List<String>? itemIds,
) {
  if (itemIds == null) return;
  final selected = itemIds.toSet();
  final visible = {
    for (final detail in details)
      for (final line in detail.lines) line.inspectionItemId,
  };
  if (selected.isEmpty ||
      selected.length > 100 ||
      !visible.containsAll(selected)) {
    throw ApiException('CONFLICT', '所选品质放行明细已变化，请刷新后重新选择');
  }
}
