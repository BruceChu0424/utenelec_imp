import '../../../core/performance/ui_work_budget.dart';
import '../../employee/models/employee_api_models.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../employee/repositories/employee_roster_loader.dart';

/// One complete, currently authorized membership snapshot for roster and chart.
/// It never converts a partial page window into a complete department result.
class DepartmentRosterSnapshot {
  const DepartmentRosterSnapshot._(this.employees, this.byDepartment);

  final List<EmployeeSummary> employees;
  final Map<String, List<EmployeeSummary>> byDepartment;
}

Future<DepartmentRosterSnapshot> loadDepartmentRosterSnapshot({
  required EmployeeRepository repository,
  required String departmentId,
  required bool Function() isCurrent,
  UiWorkBudget? budget,
}) async {
  final work = budget ?? UiWorkBudget(isCurrent: isCurrent);
  work.ensureCurrent();
  List<EmployeeSummary> employees = const [];
  var complete = false;
  await loadEmployeeRoster(
    repository: repository,
    departmentId: departmentId,
    includeSubtree: true,
    requireStableTotal: true,
    isCurrent: isCurrent,
    onBatch: (items, _, hasMore) {
      employees = items;
      complete = !hasMore;
    },
  );
  work.ensureCurrent();
  if (!isCurrent()) throw const UiWorkCancelled();
  if (!complete) throw const FormatException('员工名册未完整返回，请刷新后重试');
  final grouped = <String, List<EmployeeSummary>>{};
  for (final employee in employees) {
    final department = employee.departmentId;
    if (department != null) {
      grouped.putIfAbsent(department, () => []).add(employee);
    }
    await work.checkpoint();
  }
  final frozen = <String, List<EmployeeSummary>>{};
  for (final entry in grouped.entries) {
    frozen[entry.key] = List<EmployeeSummary>.unmodifiable(entry.value);
    await work.checkpoint();
  }
  work.ensureCurrent();
  if (!isCurrent()) throw const UiWorkCancelled();
  return DepartmentRosterSnapshot._(employees, Map.unmodifiable(frozen));
}
