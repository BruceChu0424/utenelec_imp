// 我的部门（工作台卡片用）数据接入。后端 MyDepartmentController / DepartmentStaffPermissionController。
// 任意已登录员工可见本部门分支；部门负责人额外可管理部门员工权限（问题 #20）。
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

  /// 指定部门的花名册（仅安全字段：工号/姓名/岗位/办公电话/邮箱/是否负责人/是否本人）。
  Future<MyDepartmentRoster> roster(String departmentId) async {
    final json = await _api.get(
      ApiEndpoints.myDepartmentRoster,
      query: {'departmentId': departmentId},
    );
    return MyDepartmentRoster.fromJson(json);
  }

  /// 部门负责人的「本部门员工权限」面板数据（非负责人 403）。
  Future<DepartmentStaffPermissions> managed() async {
    final json = await _api.get(ApiEndpoints.departmentStaffPermissionsManaged);
    return DepartmentStaffPermissions.fromJson(json);
  }

  /// 设置/清除某员工单个权限点的个人覆盖。effect: null=清除回落基线，'grant'/'revoke'。
  Future<void> setOverride(
    String employeeId,
    String code,
    String? effect,
  ) async {
    await _api.put(
      ApiEndpoints.departmentStaffPermissionOverride(employeeId, code),
      body: {'effect': effect},
    );
  }
}

/// 依赖 apiClientProvider（其内部随 connectionRecovery 重建），故网络恢复后自动重拉。
final myDepartmentRepositoryProvider = Provider<MyDepartmentRepository>(
  (ref) => MyDepartmentRepository(ref.watch(apiClientProvider)),
);
