// 仓库负责人(仓管员, ADR-115)：仓库资料页的「负责人」列、详情行与「设置负责人」。
//
// 负责关系决定两件事：仓库类通知只发给单据所在仓的负责人(没登记负责人的仓照旧发给整个
// 仓库部门)；仓库任务中心「我的仓库」按它筛选。登记在主仓上 = 负责它下面全部子仓。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';

/// 一名负责人 / 负责人候选。
class WarehouseKeeper {
  const WarehouseKeeper({
    required this.employeeId,
    required this.name,
    this.code,
    this.departmentName,
    this.hasAccount = true,
    this.warehouseMember = true,
  });

  final String employeeId;
  final String name;
  final String? code;
  final String? departmentName;

  /// 有启用中的登录账号(没有账号收不到任何通知)。
  final bool hasAccount;

  /// 属于仓库部门(主部门或兼职部门)；仓库类通知只在仓库部门里分发。
  final bool warehouseMember;

  /// 为什么这名负责人收不到仓库通知(能收到时为 null)。
  String? get noticeWarning {
    if (!hasAccount) return '没有启用的登录账号，收不到通知';
    if (!warehouseMember) return '不在仓库部门，收不到仓库类通知';
    return null;
  }

  factory WarehouseKeeper.fromJson(Map<String, dynamic> json) =>
      WarehouseKeeper(
        employeeId: json['employeeId'].toString(),
        name: (json['name'] as String?) ?? '',
        code: json['code'] as String?,
        departmentName: json['departmentName'] as String?,
        hasAccount: json['hasAccount'] != false,
        warehouseMember: json['warehouseMember'] != false,
      );
}

/// 列表「负责人」列用的一条负责关系。
class WarehouseKeeperAssignment {
  const WarehouseKeeperAssignment({
    required this.warehouseId,
    required this.employeeId,
    required this.name,
  });

  final String warehouseId;
  final String employeeId;
  final String name;

  factory WarehouseKeeperAssignment.fromJson(Map<String, dynamic> json) =>
      WarehouseKeeperAssignment(
        warehouseId: json['warehouseId'].toString(),
        employeeId: json['employeeId'].toString(),
        name: (json['name'] as String?) ?? '',
      );
}

class WarehouseKeeperRepository {
  const WarehouseKeeperRepository(this.api);

  final ApiClient api;

  /// 全部负责关系(仓库量级个位数，一次带回)。
  Future<List<WarehouseKeeperAssignment>> assignments() async {
    final list = await api.getList(ApiEndpoints.warehouseKeeperAssignments);
    return list.map(WarehouseKeeperAssignment.fromJson).toList();
  }

  Future<List<WarehouseKeeper>> keepers(String warehouseId) async {
    final list = await api.getList(ApiEndpoints.warehouseKeepers(warehouseId));
    return list.map(WarehouseKeeper.fromJson).toList();
  }

  /// 负责人候选：在职员工，仓库部门的人排前面(warehouse:edit)。
  Future<List<WarehouseKeeper>> candidates(String? keyword) async {
    final kw = keyword?.trim();
    final list = await api.getList(
      ApiEndpoints.warehouseKeeperCandidates,
      query: {if (kw != null && kw.isNotEmpty) 'keyword': kw},
    );
    return list.map(WarehouseKeeper.fromJson).toList();
  }

  /// 整组替换负责人；空列表 = 清空(该仓的通知回到整个仓库部门)。
  Future<List<WarehouseKeeper>> replace(
    String warehouseId,
    List<String> employeeIds,
  ) async {
    final list = await api.putList(
      ApiEndpoints.warehouseKeepers(warehouseId),
      body: {'employeeIds': employeeIds},
    );
    return list.map(WarehouseKeeper.fromJson).toList();
  }
}

final warehouseKeeperRepositoryProvider = Provider<WarehouseKeeperRepository>(
  (ref) => WarehouseKeeperRepository(ref.watch(apiClientProvider)),
);
