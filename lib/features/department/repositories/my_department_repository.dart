// “我的部门”安全花名册数据接入。权限委派已迁至 shared/auth 的页面级仓库，
// 本仓库不再接触中央个人覆盖或负责人委派写接口。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/department_node.dart';
import '../models/my_department.dart';

class MyDepartmentRepository {
  const MyDepartmentRepository(this._api);

  final ApiClient _api;

  /// 当前用户所在「大部门」（管理中心/决策层）的分支子树。
  Future<List<DepartmentNode>> myBranchTree() async {
    final list = await _api.getList(ApiEndpoints.myDepartmentTree);
    return list.map(DepartmentNode.fromJson).toList();
  }

  /// 指定部门的花名册（仅安全字段：部门定位/工号/姓名/岗位/办公电话/邮箱/负责人/本人）。
  Future<MyDepartmentRoster> roster(String departmentId) async {
    final json = await _api.get(
      ApiEndpoints.myDepartmentRoster,
      query: {'departmentId': departmentId},
    );
    return MyDepartmentRoster.fromJson(json);
  }
}

/// 依赖 apiClientProvider（其内部随 connectionRecovery 重建），故网络恢复后自动重拉。
final myDepartmentRepositoryProvider = Provider<MyDepartmentRepository>(
  (ref) => MyDepartmentRepository(ref.watch(apiClientProvider)),
);
