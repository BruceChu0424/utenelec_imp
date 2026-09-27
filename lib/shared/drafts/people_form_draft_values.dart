import '../../features/department/widgets/uten_department_picker.dart';

List<Map<String, dynamic>> draftDepartments(List<DeptSelection> values) => [
  for (final item in values)
    {
      'id': item.id,
      'name': item.name,
      'fullPath': item.fullPath,
      'level': item.level,
    },
];

List<DeptSelection> restoreDraftDepartments(Object? raw) => [
  if (raw is List<dynamic>)
    for (final item in raw.whereType<Map<String, dynamic>>())
      DeptSelection(
        id: item['id'] as String,
        name: item['name'] as String? ?? '',
        fullPath: item['fullPath'] as String? ?? '',
        level: item['level'] as String? ?? '',
      ),
];
