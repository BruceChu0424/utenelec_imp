// 仓库负责人(仓管员, ADR-115 / ADR-149)：仓库资料页的「负责人」列、详情行与「设置负责人」。
//
// 负责关系决定谁看、谁收仓库任务(服务端唯一判定)：登记在主仓上 = 仓库主管(看全部、可挑任一仓)；
// 登记在子仓上 = 只看、只收自己负责的仓；没登记负责人的仓，任务交主管、通知发主管，
// 没登记的同事也看得到。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/gen/app_localizations.dart';
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
    this.duplicateName = false,
  });

  final String employeeId;
  final String name;
  final String? code;
  final String? departmentName;

  /// 有启用中的登录账号(没有账号 = 不是有效负责人：看不到任务、收不到通知)。
  final bool hasAccount;

  /// 属于仓库部门(主部门或兼职部门)。部门外的负责人也按登记的仓看任务、收通知,
  /// 前提是另有对应的仓库任务权限(ADR-149)。
  final bool warehouseMember;

  /// 还有同名的在职员工(按工号核对, 防止登记到没账号的那份档案上)。
  final bool duplicateName;

  /// 这名负责人登记后需要留意的地方(没有时为 null)。
  String? warningOf(AppLocalizations l10n) {
    if (!hasAccount) return l10n.warehouseKeeperNoAccount;
    if (!warehouseMember) return l10n.warehouseKeeperOutsideDepartment;
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
        duplicateName: json['duplicateName'] == true,
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
