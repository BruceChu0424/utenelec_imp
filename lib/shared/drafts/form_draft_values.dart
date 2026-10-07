import 'package:flutter/material.dart';

import '../../components/inputs/uten_employee_picker.dart';
import '../../components/layout/uten_editable_grid.dart';
import 'form_draft_field_codec.dart';

export 'form_draft_field_codec.dart';

/// Recovery snapshots retain raw input, including incomplete decimal strings.
Map<String, dynamic> draftTextValues(
  Map<String, TextEditingController> controllers,
) => {for (final entry in controllers.entries) entry.key: entry.value.text};

void restoreDraftTextValues(
  Map<String, TextEditingController> controllers,
  Map<String, dynamic> data,
) {
  for (final entry in controllers.entries) {
    if (data[entry.key] is String) entry.value.text = data[entry.key] as String;
  }
}

List<Map<String, dynamic>> draftEmployees(
  Map<String, UtenEmployeePickerItem> cache,
) => [
  for (final item in cache.values)
    {
      'id': item.id,
      'name': item.name,
      'employeeCode': item.employeeCode,
      'departmentId': item.departmentId,
      'departmentName': item.departmentName,
      'subtitle': item.subtitle,
    },
];

void restoreDraftEmployees(
  Map<String, UtenEmployeePickerItem> cache,
  Object? value,
) {
  for (final item in draftMaps(value)) {
    if (item['id'] is! String) continue;
    final employee = UtenEmployeePickerItem(
      id: item['id'] as String,
      name: item['name'] as String? ?? '',
      employeeCode: item['employeeCode'] as String?,
      departmentId: item['departmentId'] as String?,
      departmentName: item['departmentName'] as String?,
      subtitle: item['subtitle'] as String?,
    );
    cache[employee.id] = employee;
  }
}

List<Map<String, dynamic>> draftGridRows<T extends EditableGridRow>(
  UtenEditableGridController<T> grid,
  Map<String, dynamic> Function(T) encode,
) => [
  for (final row in grid.rows)
    {...encode(row), 'selected': grid.isSelected(row)},
];

void restoreDraftGrid<T extends EditableGridRow>(
  UtenEditableGridController<T> grid,
  Object? value,
  T Function(Map<String, dynamic>) decode,
) {
  final maps = draftMaps(value);
  final rows = maps.map(decode).toList();
  grid.clearSelection();
  grid.replaceAll(rows);
  grid.setSelected([
    for (var i = 0; i < rows.length; i++)
      if (maps[i]['selected'] == true) rows[i],
  ], true);
}
