// 部门仓库：树/子树/详情/CRUD。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/department_node.dart';
import '../models/workforce_overview.dart';

abstract interface class DepartmentRepository {
  Future<List<DepartmentNode>> tree();
  Future<List<DepartmentNode>> subtree(String id);
  Future<DepartmentInfo> detail(String id);
  Future<WorkforceOverview> workforceOverview(String id);
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
  Future<WorkforceOverview> workforceOverview(String id) async {
    final json = await api.get(ApiEndpoints.departmentWorkforceOverview(id));
    return WorkforceOverview.fromJson(json);
  }

  @override
  Future<DepartmentInfo> create(DepartmentSaveInput input) async {
    final json = await api.post(ApiEndpoints.departments, body: input.toJson());
    return DepartmentInfo.fromJson(json);
  }

  @override
  Future<DepartmentInfo> update(String id, DepartmentUpdateInput input) async {
    final json = await api.put(
      ApiEndpoints.department(id),
      body: input.toJson(),
    );
    return DepartmentInfo.fromJson(json);
  }

  @override
  Future<void> delete(String id) => api.delete(ApiEndpoints.department(id));
}

final departmentRepositoryProvider = Provider<DepartmentRepository>(
  (ref) => DioDepartmentRepository(ref.watch(apiClientProvider)),
);

/// 部门 code → id 映射（员工选择器按职能部门收敛用：业务员→MKT_CENTER、生产工→DEPT_PROD、
/// 经办人→DEPT_FIN、委外→DEPT_SALES 等）。首次读取加载整棵部门树并扁平化；失败/未就绪返回空
/// map，picker 回退全公司。各编辑页 _employeePicker 关键字为空时用它收敛、有关键字时全公司搜。
final departmentCodeIdMapProvider = FutureProvider<Map<String, String>>((
  ref,
) async {
  final tree = await ref.read(departmentRepositoryProvider).tree();
  final map = <String, String>{};
  void walk(List<DepartmentNode> nodes) {
    for (final n in nodes) {
      map[n.code] = n.id;
      walk(n.children);
    }
  }

  walk(tree);
  return map;
});
