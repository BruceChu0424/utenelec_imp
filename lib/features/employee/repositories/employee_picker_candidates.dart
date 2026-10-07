import '../models/employee_api_models.dart';
import 'employee_repository.dart';

/// Load every page of the caller's existing employee query. Department grouping
/// must not silently omit people beyond the first page or widen its scope.
Future<List<EmployeeSummary>> loadEmployeePickerCandidates(
  EmployeeRepository repository, {
  int size = 100,
  String? search,
  Set<String>? statuses,
  String? departmentId,
  bool includeSubtree = false,
  String? sort,
  String? order,
}) async {
  final scopedStatuses = statuses == null ? null : Set<String>.of(statuses);
  final employees = <String, EmployeeSummary>{};
  var page = 1;
  while (true) {
    final result = await repository.list(
      page: page,
      size: size,
      search: search,
      statuses: scopedStatuses,
      departmentId: departmentId,
      includeSubtree: includeSubtree,
      sort: sort,
      order: order,
    );
    if (result.page != page) {
      throw const FormatException('员工候选分页响应与请求不一致');
    }
    for (final employee in result.items) {
      employees[employee.id] = employee;
    }
    if (page >= result.totalPages) break;
    page++;
  }
  return employees.values.toList(growable: false);
}

extension EmployeeRepositoryPickerCandidates on EmployeeRepository {
  Future<List<EmployeeSummary>> listPickerCandidates({
    int size = 100,
    String? search,
    Set<String>? statuses,
    String? departmentId,
    bool includeSubtree = false,
    String? sort,
    String? order,
  }) => loadEmployeePickerCandidates(
    this,
    size: size,
    search: search,
    statuses: statuses,
    departmentId: departmentId,
    includeSubtree: includeSubtree,
    sort: sort,
    order: order,
  );
}
