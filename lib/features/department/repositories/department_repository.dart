// 部门仓库：树/子树/详情/CRUD。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/department_node.dart';

abstract interface class DepartmentRepository {
  Future<List<DepartmentNode>> tree();
  Future<List<DepartmentNode>> subtree(String id);
  Future<DepartmentInfo> detail(String id);
  Future<DepartmentInfo> create(DepartmentSaveInput input);
  Future<DepartmentInfo> update(String id, DepartmentUpdateInput input);
  Future<void> delete(String id);
}

class DioDepartmentRepository implements DepartmentRepository {
  DioDepartmentRepository(this.api);
  final ApiClient api;

  @override
  Future<List<DepartmentNode>> tree() async {
    final list = await api.getList(ApiEndpoints.departmentsTree);
    return list.map(DepartmentNode.fromJson).toList();
  }

  @override
  Future<List<DepartmentNode>> subtree(String id) async {
    final list = await api.getList(ApiEndpoints.departmentSubtree(id));
    return list.map(DepartmentNode.fromJson).toList();
  }

  @override
  Future<DepartmentInfo> detail(String id) async {
    final json = await api.get(ApiEndpoints.department(id));
    return DepartmentInfo.fromJson(json);
  }

  @override
  Future<DepartmentInfo> create(DepartmentSaveInput input) async {
    final json = await api.post(ApiEndpoints.departments, body: input.toJson());
    return DepartmentInfo.fromJson(json);
  }

  @override
  Future<DepartmentInfo> update(String id, DepartmentUpdateInput input) async {
    final json = await api.put(ApiEndpoints.department(id), body: input.toJson());
    return DepartmentInfo.fromJson(json);
  }

  @override
  Future<void> delete(String id) => api.delete(ApiEndpoints.department(id));
}

final departmentRepositoryProvider = Provider<DepartmentRepository>(
  (ref) => DioDepartmentRepository(ref.watch(apiClientProvider)),
);
