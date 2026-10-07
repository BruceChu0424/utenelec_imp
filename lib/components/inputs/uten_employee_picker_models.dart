import '../../shared/formatters/employee_display.dart';

/// A candidate already authorized by the calling business workflow.
class UtenEmployeePickerItem {
  const UtenEmployeePickerItem({
    required this.id,
    required this.name,
    this.employeeCode,
    this.departmentId,
    this.departmentName,
    this.subtitle,
    this.enabled = true,
    this.disabledReason,
  });

  final String id;
  final String name;
  final String? employeeCode;

  /// Stable department identity. Names and subtitles never identify a group.
  final String? departmentId;
  final String? departmentName;

  /// Business information such as employment status, role or responsibility.
  final String? subtitle;
  final bool enabled;
  final String? disabledReason;

  String get displayName => formatEmployeeDisplayName(name, employeeCode);

  /// Compare data, not object identity: rebuilding with equivalent candidates
  /// must not cancel a user's in-progress selection.
  bool sameSnapshot(UtenEmployeePickerItem? other) =>
      other != null &&
      id == other.id &&
      name == other.name &&
      employeeCode == other.employeeCode &&
      departmentId == other.departmentId &&
      departmentName == other.departmentName &&
      subtitle == other.subtitle &&
      enabled == other.enabled &&
      disabledReason == other.disabledReason;
}

bool sameEmployeePickerSelection(
  List<UtenEmployeePickerItem> first,
  List<UtenEmployeePickerItem> second,
) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (!first[index].sameSnapshot(second[index])) return false;
  }
  return true;
}

typedef UtenEmployeePickerLoader =
    Future<List<UtenEmployeePickerItem>> Function(String? keyword);
