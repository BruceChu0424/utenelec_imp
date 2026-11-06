import '../../../components/inputs/uten_employee_picker.dart';
import '../../../core/network/api_exception.dart';
import '../repositories/client_repository.dart';

/// Single-customer and batch settings share one explicitly paged authorized source.
Future<UtenEmployeePickerPage> loadClientAccessEmployeePage(
  ClientRepository repository,
  UtenEmployeePickerQuery query, {
  Set<String> excludeEmployeeIds = const {},
}) async {
  final excluded = Set<String>.of(excludeEmployeeIds);
  final result = await repository.accessCandidates(
    page: query.page,
    size: 100,
    search: query.keyword,
    departmentId: query.departmentId,
    includeSubtree: query.includeDepartmentSubtree,
    excludeEmployeeIds: excluded,
  );
  if (result.page != query.page) {
    throw ApiException('INVALID_PAGINATION', '候选人员分页已变化，请重新搜索');
  }
  return UtenEmployeePickerPage(
    items: [
      for (final employee in result.items)
        if (employee.activeAccount && !excluded.contains(employee.employeeId))
          UtenEmployeePickerItem(
            id: employee.employeeId,
            name: employee.name,
            employeeCode: employee.code,
            departmentId: employee.departmentId,
            departmentName: employee.departmentName,
            accountStatus: employee.accountStatus,
            employmentStatus: employee.employmentStatus,
          ),
    ],
    page: result.page,
    totalPages: result.totalPages,
      total: result.total,
  );
}
