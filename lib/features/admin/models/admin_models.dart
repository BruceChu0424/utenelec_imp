// 权限管理（超级管理员）数据模型。
// 对应后端接口契约：/admin/users · /admin/permissions · /admin/permission-catalog
// · /admin/users/{id}/permission-overrides · /admin/users/{id}/effective-permissions
// · /admin/departments/{id}/permissions。角色体系已下线（ADR-011/V29）。

import '../../../shared/auth/permission_action_type.dart';

/// 员工账号摘要（GET /admin/users 的 items[]）。
class AdminUserSummary {
  const AdminUserSummary({
    required this.id,
    required this.loginAccount,
    required this.status,
    required this.mustChangePassword,
    required this.roles,
    required this.remoteAccess,
    this.employeeId,
    this.employeeStatus,
    this.currentEmployee = false,
    this.employeeName,
    this.employeeCode,
    this.lastLoginAt,
    this.departmentId,
    this.departmentName,
    this.tempPasswordExpiresAt,
  });

  final String id;
  final String loginAccount;

  /// 'active' | 'locked' | 'disabled'
  final String status;
  final bool mustChangePassword;

  /// 已分配的角色 code 列表（历史遗留字段，后端仍返回；角色体系下线后仅作展示参考，不参与权限）
  final List<String> roles;

  /// 是否授权云端(外网)访问。仅 remote_access=TRUE 的账号可在云端实例登录；
  /// 权限页顶部「云端访问」开关据此回显，授权后该账号须重新登录拿新 token。
  final bool remoteAccess;

  final String? employeeId;
  final String? employeeStatus;
  final bool currentEmployee;
  final String? employeeName;
  final String? employeeCode;
  final String? lastLoginAt;
  final String? departmentId;
  final String? departmentName;

  /// 管理员设置的临时密码有效期截止（ISO 字符串，V297）；null = 无临时密码或不设有效期。
  final String? tempPasswordExpiresAt;

  bool get authorizationGrantAllowed => currentEmployee && status == 'active';

  bool get passwordResetAllowed => currentEmployee || status == 'disabled';

  String get employeeStatusLabel {
    switch (employeeStatus?.trim()) {
      case 'active':
        return '在职';
      case 'probation':
        return '试用';
      case 'onLeave':
        return '留职';
      case 'resigned':
        return '已离职';
      case null:
      case '':
        return '任职状态未知';
      default:
        return employeeStatus!.trim();
    }
  }

  String get lifecycleRestrictionReason {
    if (currentEmployee) return '';
    if (employeeStatus?.trim() == 'resigned') {
      return '员工已离职，需先完成复职流程';
    }
    if (employeeStatus?.trim().isEmpty ?? true) {
      return '员工任职状态无法确认，需先在员工档案确认或完成复职流程';
    }
    return '员工为非在职状态，需先完成复职流程';
  }

  String get authorizationRestrictionReason {
    if (!currentEmployee) return lifecycleRestrictionReason;
    if (status != 'active') return '账号未启用，需先启用账号后再新增授权';
    return '';
  }

  factory AdminUserSummary.fromJson(Map<String, dynamic> json) =>
      AdminUserSummary(
        id: json['id'] as String,
        loginAccount: json['loginAccount'] as String? ?? '',
        status: json['status'] as String? ?? 'active',
        mustChangePassword: json['mustChangePassword'] as bool? ?? false,
        roles: (json['roles'] as List<dynamic>? ?? const [])
            .map((e) => e as String)
            .toList(),
        employeeId: json['employeeId'] as String?,
        employeeStatus: json['employeeStatus'] as String?,
        currentEmployee: json['currentEmployee'] as bool? ?? false,
        employeeName: json['employeeName'] as String?,
        employeeCode: json['employeeCode'] as String?,
        lastLoginAt: json['lastLoginAt'] as String?,
        departmentId: json['departmentId'] as String?,
        departmentName: json['departmentName'] as String?,
        remoteAccess: json['remoteAccess'] as bool? ?? false,
        tempPasswordExpiresAt: json['tempPasswordExpiresAt'] as String?,
      );
}

/// 权限点（GET /admin/permissions）。
class AdminPermission {
  const AdminPermission({
    required this.id,
    required this.code,
    required this.name,
    required this.category,
    this.module,
    this.actionType = PermissionActionType.other,
    this.description,
  });

  final String id;
  final String code;
  final String name;

  /// 二级子类（矩阵按此折叠二级分组）
  final String category;

  /// 一级功能模块（如「基础资料」）；驱动权限目录一级分组。目录项可能不带回传，由组名兜底。
  final String? module;

  /// 后端目录给出的动作分类；缺失或未知时显示为「其它」，不根据 code 猜测。
  final PermissionActionType actionType;

  /// 面向授权人员的权限边界说明。
  final String? description;

  factory AdminPermission.fromJson(Map<String, dynamic> json) =>
      AdminPermission(
        id: json['id'] as String,
        code: json['code'] as String? ?? '',
        name: json['name'] as String? ?? '',
        category: json['category'] as String? ?? '其他',
        module: json['module'] as String?,
        actionType: PermissionActionType.fromJson(json['actionType']),
        description: _nullableTrimmed(json['description']),
      );
}

/// 个人权限覆盖（GET /admin/users/{id}/permission-overrides）。
class UserPermOverrides {
  const UserPermOverrides({required this.grants, required this.revokes});

  /// 加授的权限点 code 列表
  final List<String> grants;

  /// 回收的权限点 code 列表
  final List<String> revokes;

  factory UserPermOverrides.fromJson(Map<String, dynamic> json) =>
      UserPermOverrides(
        grants: (json['grants'] as List<dynamic>? ?? const [])
            .map((e) => e as String)
            .toList(),
        revokes: (json['revokes'] as List<dynamic>? ?? const [])
            .map((e) => e as String)
            .toList(),
      );
}

/// 权限目录分组（GET /admin/permission-catalog 的数组项）。
/// 目录是动态的：后端返回什么前端显示什么，不硬编码权限清单。
/// 两级：[module] 一级功能模块 → [category] 二级子类 → permissions。
class PermissionCatalogGroup {
  const PermissionCatalogGroup({
    required this.module,
    required this.category,
    required this.permissions,
  });

  /// 一级模块（如「基础资料」「销售管理」）。
  final String module;

  /// 二级子类（如「货品资料」「销售订货」）。
  final String category;

  /// 该分组下的权限点（已按后端排序）
  final List<AdminPermission> permissions;

  factory PermissionCatalogGroup.fromJson(Map<String, dynamic> json) {
    final category = json['category'] as String? ?? '其他';
    final module = json['module'] as String? ?? '其他';
    return PermissionCatalogGroup(
      module: module,
      category: category,
      permissions: (json['permissions'] as List<dynamic>? ?? const []).map((e) {
        final p = e as Map<String, dynamic>;
        final code = p['code'] as String? ?? '';
        // 目录项可能不带 id/module/category，用 code 兜底 id、组名兜底 module/category
        return AdminPermission(
          id: p['id'] as String? ?? code,
          code: code,
          name: p['name'] as String? ?? '',
          category: p['category'] as String? ?? category,
          module: p['module'] as String? ?? module,
          actionType: PermissionActionType.fromJson(p['actionType']),
          description: _nullableTrimmed(p['description']),
        );
      }).toList(),
    );
  }
}

String? _nullableTrimmed(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}

/// 员工有效权限（GET /admin/users/{id}/effective-permissions）。
/// effective 由后端计算：全员基础 ∪ 部门配置 ∪ 个人加授 − 个人收回
/// ∪ 负责人委派（managerGrants，含来源快照与代际失效）。
class EffectivePermissions {
  const EffectivePermissions({
    required this.departmentPermissions,
    required this.baselinePermissions,
    required this.grants,
    required this.revokes,
    required this.effective,
    this.managerGrants = const [],
    this.confirmedGrants = const [],
    this.legacyUnknownGrants = const [],
    this.legacyUnknownRevokes = const [],
    this.departmentId,
    this.departmentName,
    this.superAdmin = false,
  });

  final String? departmentId;
  final String? departmentName;

  /// 超级管理员：恒为全量权限，权限页据此全部显示"已授权"且不可调整
  final bool superAdmin;

  /// 所在部门已配置的权限点 code 列表
  final List<String> departmentPermissions;

  /// 全员基础权限点 code 列表（人人有份，角色体系下线后仅保留基础包）
  final List<String> baselinePermissions;

  /// 个人加授的权限点 code 列表
  final List<String> grants;

  /// 个人收回的权限点 code 列表
  final List<String> revokes;

  /// 当前有效的组织负责人委派来源；中央个人 revoke 对其保持最高优先级。
  final List<String> managerGrants;

  /// 超级管理员已在全局权限页明确确认的个人 grant。
  final List<String> confirmedGrants;

  /// V319 前来源不可证明的历史覆盖：继续生效，但 grant 不可作为负责人二次转授来源。
  final List<String> legacyUnknownGrants;
  final List<String> legacyUnknownRevokes;

  /// 最终有效权限点 code 列表（后端计算结果，前端以此为准）
  final List<String> effective;

  static List<String> _codes(Map<String, dynamic> json, String key) =>
      (json[key] as List<dynamic>? ?? const [])
          .map((e) => e as String)
          .toList();

  factory EffectivePermissions.fromJson(Map<String, dynamic> json) =>
      EffectivePermissions(
        departmentId: json['departmentId'] as String?,
        departmentName: json['departmentName'] as String?,
        departmentPermissions: _codes(json, 'departmentPermissions'),
        baselinePermissions: _codes(json, 'baselinePermissions'),
        grants: _codes(json, 'grants'),
        revokes: _codes(json, 'revokes'),
        managerGrants: _codes(json, 'managerGrants'),
        confirmedGrants: _codes(json, 'confirmedGrants'),
        legacyUnknownGrants: _codes(json, 'legacyUnknownGrants'),
        legacyUnknownRevokes: _codes(json, 'legacyUnknownRevokes'),
        effective: _codes(json, 'effective'),
        superAdmin: json['superAdmin'] as bool? ?? false,
      );
}

/// 数据范围授权归属人候选（范围内实际有归属数据的员工）。
class DataScopeOwner {
  const DataScopeOwner({
    required this.employeeId,
    required this.name,
    required this.count,
    this.code,
    this.status,
    this.historicalOnly = false,
  });

  final String employeeId;
  final String name;
  final String? code;
  final int count;
  final String? status;
  final bool historicalOnly;

  factory DataScopeOwner.fromJson(Map<String, dynamic> json) => DataScopeOwner(
    employeeId: json['employeeId'] as String? ?? '',
    name: json['name'] as String? ?? '',
    code: json['code'] as String?,
    count: (json['count'] as num?)?.toInt() ?? 0,
    status: json['status'] as String?,
    historicalOnly: json['historicalOnly'] as bool? ?? false,
  );
}

class DataScopeCatalogItem {
  const DataScopeCatalogItem({
    required this.scope,
    required this.label,
    required this.description,
    required this.viewAllPermission,
    required this.enabled,
    required this.group,
    this.disabledReason,
  });

  final String scope;
  final String label;
  final String description;
  final String viewAllPermission;
  final bool enabled;
  final String group;
  final String? disabledReason;

  String get displayLabel => label
      .replaceAll('外贸货品', '货品资料')
      .replaceAll('业务员', '负责人')
      .replaceAll('制单人', '负责人');

  String get displayDescription => description
      .replaceAll('外贸货品', '货品资料')
      .replaceAll('业务员', '负责人')
      .replaceAll('制单人', '负责人');

  factory DataScopeCatalogItem.fromJson(Map<String, dynamic> json) =>
      DataScopeCatalogItem(
        scope: json['scope'] as String? ?? '',
        label: json['label'] as String? ?? '',
        description: json['description'] as String? ?? '',
        viewAllPermission: json['viewAllPermission'] as String? ?? '',
        enabled: json['enabled'] as bool? ?? false,
        disabledReason: json['disabledReason'] as String?,
        group: json['group'] as String? ?? '其他',
      );
}

/// 开通账号候选员工（GET /admin/users/provision-candidates）。
/// 最小信息集：姓名/工号/部门 + 是否已登记手机号/证件（不回传 PII 明文）。
class AccountProvisionCandidate {
  const AccountProvisionCandidate({
    required this.employeeId,
    required this.name,
    required this.code,
    required this.hasPhone,
    required this.hasIdCard,
    this.departmentName,
  });

  final String employeeId;
  final String name;
  final String code;
  final String? departmentName;

  /// 已登记手机号（登录账号=手机号，缺失时无法开通）。
  final bool hasPhone;

  /// 已登记证件号（初始密码=证件号后 6 位，缺失时无法开通）。
  final bool hasIdCard;

  /// 满足开通条件（缺少资料时后端会拒绝，前端提前置灰提示）。
  bool get provisionable => hasPhone && hasIdCard;

  /// 不可开通的缺失资料说明（如「缺手机号、证件号」）。
  String get missingHint {
    final missing = [if (!hasPhone) '手机号', if (!hasIdCard) '证件号'];
    return missing.isEmpty ? '' : '缺${missing.join('、')}';
  }

  factory AccountProvisionCandidate.fromJson(Map<String, dynamic> json) =>
      AccountProvisionCandidate(
        employeeId: json['employeeId'] as String,
        name: json['name'] as String? ?? '',
        code: json['code'] as String? ?? '',
        departmentName: json['departmentName'] as String?,
        hasPhone: json['hasPhone'] as bool? ?? false,
        hasIdCard: json['hasIdCard'] as bool? ?? false,
      );
}
