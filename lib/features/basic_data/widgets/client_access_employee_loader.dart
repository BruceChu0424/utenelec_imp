import '../../../components/inputs/uten_employee_picker.dart';
import '../../../core/network/api_exception.dart';
import '../models/client_access_models.dart';
import '../repositories/client_repository.dart';

/// Shared candidate contract for single-customer and batch responsibility settings.
Future<List<UtenEmployeePickerItem>> loadClientAccessEmployees(
  ClientRepository repository,
  String? keyword,
) async {
  final rows = <ClientAccessCandidate>[];
  var page = 1;
  var total = 1;
  do {
    final result = await repository.accessCandidates(
      page: page,
      size: 100,
      search: keyword,
    );
    if (result.total > 5000) {
      throw ApiException('VALIDATION_FAILED', '候选人员超过5000人，请输入姓名或工号缩小范围');
    }
    if (result.items.isEmpty && rows.length < result.total) {
      throw ApiException('CONFLICT', '候选人员已变化，请重新搜索');
    }
    rows.addAll(result.items);
    total = result.total;
    page++;
  } while (rows.length < total);
  return rows
      .where((employee) => employee.activeAccount)
      .map(
        (employee) => UtenEmployeePickerItem(
          id: employee.employeeId,
          name: employee.name,
          employeeCode: employee.code,
          departmentId: employee.departmentId,
          departmentName: employee.departmentName,
          accountStatus: employee.accountStatus,
          employmentStatus: employee.employmentStatus,
        ),
      )
      .toList(growable: false);
}
