import '../../components/inputs/uten_employee_picker.dart';
import '../../components/layout/uten_editable_grid.dart';
import '../providers/master_name_provider.dart';

/// Editor snapshots preserve text exactly, including incomplete numeric input.
String draftText(Map<String, dynamic> data, String key) =>
    data[key] as String? ?? '';

Map<String, dynamic> draftMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

List<Map<String, dynamic>> draftMaps(Object? value) => value is List
    ? value
          .whereType<Map<dynamic, dynamic>>()
          .map((v) => Map<String, dynamic>.from(v))
          .toList()
    : <Map<String, dynamic>>[];

List<String> draftStrings(Object? value) =>
    value is List ? value.whereType<String>().toList() : <String>[];

Map<String, dynamic>? draftGoods(GoodsOption? goods) => goods == null
    ? null
    : {'id': goods.id, 'name': goods.name, 'code': goods.code};

GoodsOption? restoreDraftGoods(Object? value) {
  final data = draftMap(value);
  return data['id'] is String ? GoodsOption.fromJson(data) : null;
}

Map<String, dynamic> draftEmployee(UtenEmployeePickerItem employee) => {
  'id': employee.id,
  'name': employee.name,
  'employeeCode': employee.employeeCode,
  'departmentName': employee.departmentName,
};

UtenEmployeePickerItem restoreDraftEmployee(Map<String, dynamic> data) =>
    UtenEmployeePickerItem(
      id: draftText(data, 'id'),
      name: draftText(data, 'name'),
      employeeCode: data['employeeCode'] as String?,
      departmentName: data['departmentName'] as String?,
    );

List<int> draftGridSelection<T extends EditableGridRow>(
  UtenEditableGridController<T> grid,
) => [
  for (var index = 0; index < grid.length; index++)
    if (grid.isSelected(grid[index])) index,
];

void restoreDraftGridSelection<T extends EditableGridRow>(
  UtenEditableGridController<T> grid,
  Object? value,
) {
  grid.clearSelection();
  if (value is! List) return;
  grid.setSelected([
    for (final index in value.whereType<int>())
      if (index >= 0 && index < grid.length) grid[index],
  ], true);
}
