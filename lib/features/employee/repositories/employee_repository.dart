// 员工仓库：分页列表/详情/入职/调岗/离职/删除。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../models/employee_api_models.dart';

abstract interface class EmployeeRepository {
  Future<PagedResult<EmployeeSummary>> list({
    int page = 1,
    int size = 20,
    String? search,
    Set<String>? statuses,
    String? departmentId,
    bool includeSubtree = false,
  });
  Future<EmployeeProfile> getById(String id);
  Future<EmployeeProfile> create(EmployeeOnboardingInput input);
  Future<EmployeeProfile> update(String id, Map<String, dynamic> body);
  Future<void> transfer(String id, Map<String, dynamic> body);
  Future<void> offboard(String id, Map<String, dynamic> body);
  Future<void> confirm(String id);
  Future<void> rehire(String id);
  Future<void> delete(String id);
}

class DioEmployeeRepository implements EmployeeRepository {
  DioEmployeeRepository(this.api);
  final ApiClient api;

  @override
  Future<PagedResult<EmployeeSummary>> list({
    int page = 1,
    int size = 20,
    String? search,
    Set<String>? statuses,
    String? departmentId,
    bool includeSubtree = false,
  }) async {
    final query = <String, dynamic>{
      'page': page,
      'size': size,
      if (search != null && search.isNotEmpty) 'search': search,
      if (departmentId != null) 'departmentId': departmentId,
      'includeSubtree': includeSubtree,
      if (statuses != null && statuses.isNotEmpty) 'statuses': statuses.toList(),
    };
    final json = await api.get(ApiEndpoints.employees, query: query);
    return PagedResult.fromJson(json, EmployeeSummary.fromJson);
  }

  @override
  Future<EmployeeProfile> getById(String id) async {
    final json = await api.get(ApiEndpoints.employee(id));
    return EmployeeProfile.fromJson(json);
  }

  @override
  Future<EmployeeProfile> create(EmployeeOnboardingInput input) async {
    final json = await api.post(ApiEndpoints.employees, body: input.toJson());
    return EmployeeProfile.fromJson(json);
  }

  @override
  Future<EmployeeProfile> update(String id, Map<String, dynamic> body) async {
    final json = await api.put(ApiEndpoints.employee(id), body: body);
    return EmployeeProfile.fromJson(json);
  }

  @override
  Future<void> transfer(String id, Map<String, dynamic> body) =>
      api.post(ApiEndpoints.employeeTransfer(id), body: body);

  @override
  Future<void> offboard(String id, Map<String, dynamic> body) =>
      api.post(ApiEndpoints.employeeOffboard(id), body: body);

  @override
  Future<void> confirm(String id) =>
      api.post(ApiEndpoints.employeeConfirm(id));

  @override
  Future<void> rehire(String id) => api.post(ApiEndpoints.employeeRehire(id));

  @override
  Future<void> delete(String id) => api.delete(ApiEndpoints.employee(id));
}

final employeeRepositoryProvider = Provider<EmployeeRepository>(
  (ref) => DioEmployeeRepository(ref.watch(apiClientProvider)),
);
