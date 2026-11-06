import '../../shared/formatters/employee_display.dart';
import '../../shared/models/department_node.dart';

enum UtenEmployeePickerPresentation { standard, businessReference }

/// A candidate already authorized by the calling business workflow.
class UtenEmployeePickerItem {
  const UtenEmployeePickerItem({
    required this.id,
    required this.name,
    this.employeeCode,
    this.departmentId,
    this.departmentName,
    this.positionName,
    this.accountStatus,
    this.employmentStatus,
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
  final String? positionName;

  /// Explicit account fact: notProvisioned/active/locked/disabled. Null means
  /// the source did not provide this information, never "not provisioned".
  final String? accountStatus;
  final String? employmentStatus;

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
      positionName == other.positionName &&
      accountStatus == other.accountStatus &&
      employmentStatus == other.employmentStatus &&
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

/// Ownership and eligibility retire a pending choice; display hydration does not.
bool sameEmployeePickerSelectionIdentity(
  List<UtenEmployeePickerItem> first,
  List<UtenEmployeePickerItem> second,
) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    final a = first[index], b = second[index];
    if (a.id != b.id ||
        a.enabled != b.enabled ||
        a.disabledReason != b.disabledReason) {
      return false;
    }
  }
  return true;
}

typedef UtenEmployeePickerLoader =
    Future<List<UtenEmployeePickerItem>> Function(String? keyword);

class UtenEmployeePickerQuery {
  const UtenEmployeePickerQuery({
    this.keyword,
    this.page = 1,
    this.departmentId,
    this.organization,
    this.departmentScopeKey,
  });
  final String? keyword;
  final int page;
  final String? departmentId;
  final List<DepartmentNode>? organization;

  /// Presentation scope preserves special directories such as unassigned
  /// historical audit accounts. Business loaders translate it explicitly.
  final String? departmentScopeKey;

  /// Unmatched historical departments retain their exact factual membership.
  bool get includeDepartmentSubtree =>
      departmentId != null &&
      _findPickerDepartment(organization ?? const [], departmentId!) != null;
}

DepartmentNode? _findPickerDepartment(
  Iterable<DepartmentNode> nodes,
  String id,
) {
  for (final node in nodes) {
    if (node.id == id) return node;
    final child = _findPickerDepartment(node.children, id);
    if (child != null) return child;
  }
  return null;
}

class UtenEmployeePickerPage {
  const UtenEmployeePickerPage({
    required this.items,
    required this.page,
    required this.totalPages,
    this.total,
  });
  const UtenEmployeePickerPage.empty({this.page = 1})
    : items = const [],
      totalPages = 0,
      total = 0;
  final List<UtenEmployeePickerItem> items;
  final int page;
  final int totalPages;
  final int? total;
}

typedef UtenEmployeePickerPagedLoader =
    Future<UtenEmployeePickerPage> Function(UtenEmployeePickerQuery query);

/// A tree click may narrow the calling workflow's scope, never widen it.
Future<({String? id, bool subtree, bool empty})> employeePickerDepartmentScope(
  UtenEmployeePickerQuery query, {
  String? departmentId,
  bool includeSubtree = false,
  required Future<List<DepartmentNode>> Function() loadDepartments,
}) async {
  final selected = query.departmentId;
  if (selected == null) {
    return (id: departmentId, subtree: includeSubtree, empty: false);
  }
  if (departmentId == null) {
    // Historical/unmatched departments are factual labels, not current tree
    // roots. Preserve their exact membership without reopening a deleted tree.
    return (
      id: selected,
      subtree: query.includeDepartmentSubtree,
      empty: false,
    );
  }
  if (selected == departmentId) {
    return (id: selected, subtree: includeSubtree, empty: false);
  }
  final tree = query.organization ?? await loadDepartments();
  final base = _findPickerDepartment(tree, departmentId);
  final chosen = _findPickerDepartment(tree, selected);
  if (includeSubtree &&
      base != null &&
      _findPickerDepartment(base.children, selected) != null) {
    return (id: selected, subtree: true, empty: false);
  }
  if (chosen != null &&
      _findPickerDepartment(chosen.children, departmentId) != null) {
    return (id: departmentId, subtree: includeSubtree, empty: false);
  }
  return (id: departmentId, subtree: includeSubtree, empty: true);
}
