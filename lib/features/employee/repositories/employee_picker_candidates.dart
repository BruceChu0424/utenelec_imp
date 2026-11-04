import '../../../components/inputs/uten_employee_picker_models.dart';
import '../../../shared/models/department_node.dart';
import 'employee_repository.dart';

/// Explicit pages keep the HR selector responsive without widening its query.
extension EmployeeRepositoryPickerCandidates on EmployeeRepository {
  Future<UtenEmployeePickerPage> listPickerPage(
    UtenEmployeePickerQuery query, {
    int size = 100,
    Set<String>? statuses,
    String? departmentId,
    bool includeSubtree = false,
    String? sort,
    String? order,
    required Future<List<DepartmentNode>> Function() loadDepartments,
  }) async {
    final statusSnapshot = statuses == null ? null : Set<String>.of(statuses);
    final scope = await employeePickerDepartmentScope(
      query,
      departmentId: departmentId,
      includeSubtree: includeSubtree,
      loadDepartments: loadDepartments,
    );
    if (scope.empty) return UtenEmployeePickerPage.empty(page: query.page);
    final result = await list(
      page: query.page,
      size: size,
      search: query.keyword,
      statuses: statusSnapshot,
      departmentId: scope.id,
      includeSubtree: scope.subtree,
      sort: sort,
      order: order,
    );
    if (result.page != query.page) {
      throw const FormatException('员工候选分页响应与请求不一致');
    }
    return UtenEmployeePickerPage(
      items: [
        for (final employee in result.items)
          UtenEmployeePickerItem(
            id: employee.id,
            name: employee.fullName,
            employeeCode: employee.code,
            accountStatus: employee.accountStatus,
            employmentStatus: employee.status,
            departmentId: employee.departmentId,
            departmentName: employee.departmentName,
            positionName: employee.positionName,
          ),
      ],
      page: result.page,
      totalPages: result.totalPages,
    );
  }
}
