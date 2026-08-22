// 页面内权限设置的数据契约。
//
// 人员列表与单人权限详情分开加载，避免部门人数增长后返回
// `员工数 × 权限数` 的完整矩阵。

import 'permission_action_type.dart';

class PageDelegationCapability {
  const PageDelegationCapability({
    required this.surfaceKey,
    required this.superAdmin,
    required this.canManage,
  });

  final String surfaceKey;
  final bool superAdmin;
  final bool canManage;

  factory PageDelegationCapability.fromJson(Map<String, dynamic> json) =>
      PageDelegationCapability(
        surfaceKey: json['surfaceKey'] as String? ?? '',
        superAdmin: json['superAdmin'] as bool? ?? false,
        canManage: json['canManage'] as bool? ?? false,
      );
}

class ManagedPermissionDepartment {
  const ManagedPermissionDepartment({
    required this.departmentId,
    required this.departmentName,
    required this.level,
    this.code = '',
    this.parentId,
    this.sortOrder = 0,
    this.selectable = true,
  });

  final String departmentId;
  final String departmentName;
  final String level;
  final String code;
  final String? parentId;
  final int sortOrder;
  final bool selectable;

  factory ManagedPermissionDepartment.fromJson(Map<String, dynamic> json) =>
      ManagedPermissionDepartment(
        departmentId: json['departmentId'] as String,
        departmentName:
            json['departmentName'] as String? ?? json['name'] as String? ?? '',
        level: json['level'] as String? ?? '',
        code: json['code'] as String? ?? '',
        parentId: json['parentId'] as String?,
        sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
        selectable: json['selectable'] as bool? ?? true,
      );
}

class PagePermissionStaffSummary {
  const PagePermissionStaffSummary({
    required this.employeeId,
    required this.departmentId,
    required this.departmentName,
    required this.departmentManager,
    required this.hasAccount,
    required this.accountActive,
    this.code,
    this.fullName,
    this.positionName,
  });

  final String employeeId;
  final String departmentId;
  final String departmentName;
  final String? code;
  final String? fullName;
  final String? positionName;
  final bool departmentManager;
  final bool hasAccount;
  final bool accountActive;

  factory PagePermissionStaffSummary.fromJson(Map<String, dynamic> json) =>
      PagePermissionStaffSummary(
        employeeId: json['employeeId'] as String,
        departmentId: json['departmentId'] as String? ?? '',
        departmentName: json['departmentName'] as String? ?? '',
        code: json['code'] as String?,
        fullName: json['fullName'] as String?,
        positionName: json['positionName'] as String?,
        departmentManager: json['departmentManager'] as bool? ?? false,
        hasAccount: json['hasAccount'] as bool? ?? false,
        accountActive:
            json['accountActive'] as bool? ??
            (json['hasAccount'] as bool? ?? false),
      );
}

class PagePermissionStaffPage {
  const PagePermissionStaffPage({
    required this.surfaceKey,
    required this.departmentId,
    required this.departmentName,
    required this.items,
    required this.page,
    required this.size,
    required this.total,
    required this.totalPages,
  });

  final String surfaceKey;

  /// `null` 表示未按单一部门筛选，结果覆盖操作者全部可管理组织范围。
  final String? departmentId;
  final String? departmentName;
  final List<PagePermissionStaffSummary> items;
  final int page;
  final int size;
  final int total;
  final int totalPages;

  bool get hasMore => page < totalPages;

  factory PagePermissionStaffPage.fromJson(
    Map<String, dynamic> json,
  ) => PagePermissionStaffPage(
    surfaceKey: json['surfaceKey'] as String? ?? '',
    departmentId: json['departmentId'] as String?,
    departmentName: json['departmentName'] as String?,
    items: ((json['items'] ?? json['staff']) as List<dynamic>? ?? const [])
        .map(
          (item) =>
              PagePermissionStaffSummary.fromJson(item as Map<String, dynamic>),
        )
        .toList(growable: false),
    page: (json['page'] as num?)?.toInt() ?? 1,
    size: (json['size'] as num?)?.toInt() ?? 0,
    total: (json['total'] as num?)?.toInt() ?? 0,
    totalPages: (json['totalPages'] as num?)?.toInt() ?? 0,
  );
}

class PageStaffPermissionState {
  const PageStaffPermissionState({
    required this.code,
    required this.name,
    required this.baseEffective,
    required this.delegationEnabled,
    required this.rowVersion,
    required this.effective,
    required this.editable,
    this.actionType = PermissionActionType.other,
    this.description,
    this.reason,
  });

  final String code;
  final String name;
  final PermissionActionType actionType;
  final String? description;
  final bool baseEffective;
  final bool delegationEnabled;
  final int rowVersion;
  final bool effective;
  final bool editable;
  final String? reason;

  factory PageStaffPermissionState.fromJson(Map<String, dynamic> json) {
    final configuredEffect = (json['configuredEffect'] as String?)
        ?.toLowerCase();
    return PageStaffPermissionState(
      code: json['code'] as String,
      name: json['name'] as String? ?? json['code'] as String,
      actionType: PermissionActionType.fromJson(json['actionType']),
      description: _optionalText(json['description']),
      baseEffective:
          (json['baseEffective'] ?? json['targetBaseEffective']) as bool? ??
          false,
      delegationEnabled:
          json['delegationEnabled'] as bool? ?? configuredEffect == 'grant',
      rowVersion: (json['rowVersion'] as num?)?.toInt() ?? 0,
      effective: json['effective'] as bool? ?? false,
      editable: json['editable'] as bool? ?? false,
      reason: json['reason'] as String?,
    );
  }
}

class PagePermissionEmployeeDetail {
  const PagePermissionEmployeeDetail({
    required this.surfaceKey,
    required this.departmentId,
    required this.departmentName,
    required this.employeeId,
    required this.departmentManager,
    required this.hasAccount,
    required this.superAdminMode,
    required this.permissions,
    this.code,
    this.fullName,
    this.positionName,
  });

  final String surfaceKey;
  final String departmentId;
  final String departmentName;
  final String employeeId;
  final String? code;
  final String? fullName;
  final String? positionName;
  final bool departmentManager;
  final bool hasAccount;
  final bool superAdminMode;
  final List<PageStaffPermissionState> permissions;

  factory PagePermissionEmployeeDetail.fromJson(Map<String, dynamic> json) {
    final employee = json['employee'] is Map<String, dynamic>
        ? json['employee'] as Map<String, dynamic>
        : json;
    final settingMode = (json['settingMode'] as String?)?.toUpperCase();
    return PagePermissionEmployeeDetail(
      surfaceKey: json['surfaceKey'] as String? ?? '',
      departmentId: json['departmentId'] as String,
      departmentName: json['departmentName'] as String? ?? '',
      employeeId: employee['employeeId'] as String,
      code: employee['code'] as String?,
      fullName: employee['fullName'] as String?,
      positionName: employee['positionName'] as String?,
      departmentManager: employee['departmentManager'] as bool? ?? false,
      hasAccount: employee['hasAccount'] as bool? ?? false,
      superAdminMode:
          json['superAdminMode'] as bool? ??
          settingMode == 'SUPER_ADMIN' || settingMode == 'CENTRAL_OVERRIDE',
      permissions: (json['permissions'] as List<dynamic>? ?? const [])
          .map(
            (item) =>
                PageStaffPermissionState.fromJson(item as Map<String, dynamic>),
          )
          .toList(growable: false),
    );
  }
}

class PagePermissionChange {
  const PagePermissionChange({
    required this.code,
    required this.enabled,
    required this.expectedVersion,
  });

  final String code;
  final bool enabled;
  final int expectedVersion;

  Map<String, dynamic> toJson() => {
    'code': code,
    'enabled': enabled,
    'expectedVersion': expectedVersion,
  };
}

String? _optionalText(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}
