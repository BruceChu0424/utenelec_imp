// "我的部门"模型（对应后端 MyDepartmentRosterDto / DepartmentStaffPermissionsDto，问题 #20）。

class MyDepartmentRoster {
  const MyDepartmentRoster({
    required this.departmentId,
    required this.departmentName,
    required this.staff,
  });

  final String departmentId;
  final String departmentName;
  final List<MyDepartmentStaffRow> staff;

  factory MyDepartmentRoster.fromJson(Map<String, dynamic> json) =>
      MyDepartmentRoster(
        departmentId: json['departmentId'] as String,
        departmentName: (json['departmentName'] ?? '') as String,
        staff: (json['staff'] as List? ?? const [])
            .map(
              (e) => MyDepartmentStaffRow.fromJson(e as Map<String, dynamic>),
            )
            .toList(),
      );
}

class MyDepartmentStaffRow {
  const MyDepartmentStaffRow({
    required this.employeeId,
    required this.departmentId,
    this.code,
    this.fullName,
    this.positionName,
    this.departmentName,
    this.officePhone,
    this.email,
    this.departmentManager = false,
    this.isSelf = false,
  });

  final String employeeId;
  final String departmentId;
  final String? code;
  final String? fullName;
  final String? positionName;
  final String? departmentName;
  final String? officePhone;
  final String? email;
  final bool departmentManager;
  final bool isSelf;

  factory MyDepartmentStaffRow.fromJson(Map<String, dynamic> json) =>
      MyDepartmentStaffRow(
        employeeId: json['employeeId'] as String,
        departmentId: json['departmentId'] as String,
        code: json['code'] as String?,
        fullName: json['fullName'] as String?,
        positionName: json['positionName'] as String?,
        departmentName: json['departmentName'] as String?,
        officePhone: json['officePhone'] as String?,
        email: json['email'] as String?,
        departmentManager: json['departmentManager'] as bool? ?? false,
        isSelf: json['isSelf'] as bool? ?? false,
      );

  /// 「我的部门」统一搜索只使用服务端已授权花名册里的安全字段。
  bool matchesSearch(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return (fullName ?? '').toLowerCase().contains(q) ||
        (code ?? '').toLowerCase().contains(q);
  }
}

/// 部门主管的"本部门员工权限"面板数据。
class DepartmentStaffPermissions {
  const DepartmentStaffPermissions({
    required this.departmentId,
    required this.departmentName,
    required this.permissionCodes,
    required this.staff,
  });

  final String departmentId;
  final String departmentName;
  final List<DepartmentPermissionItem> permissionCodes;
  final List<DepartmentStaffPermissionRow> staff;

  factory DepartmentStaffPermissions.fromJson(Map<String, dynamic> json) =>
      DepartmentStaffPermissions(
        departmentId: json['departmentId'] as String,
        departmentName: (json['departmentName'] ?? '') as String,
        permissionCodes: (json['permissionCodes'] as List? ?? const [])
            .map(
              (e) =>
                  DepartmentPermissionItem.fromJson(e as Map<String, dynamic>),
            )
            .toList(),
        staff: (json['staff'] as List? ?? const [])
            .map(
              (e) => DepartmentStaffPermissionRow.fromJson(
                e as Map<String, dynamic>,
              ),
            )
            .toList(),
      );
}

class DepartmentPermissionItem {
  const DepartmentPermissionItem({
    required this.code,
    required this.name,
    this.baseline = false,
  });
  final String code;
  final String name;

  /// 是否属于部门配置基线（部门里人人默认有）；false=负责人个人加授的额外权限。
  /// 决定前端开关初态：基线 code 默认 ON（可撤销），额外 code 默认 OFF（可授予）。
  final bool baseline;

  factory DepartmentPermissionItem.fromJson(Map<String, dynamic> json) =>
      DepartmentPermissionItem(
        code: json['code'] as String,
        name: (json['name'] ?? json['code']) as String,
        baseline: json['baseline'] as bool? ?? false,
      );
}

class DepartmentStaffPermissionRow {
  const DepartmentStaffPermissionRow({
    required this.employeeId,
    this.code,
    this.fullName,
    this.positionName,
    this.departmentManager = false,
    this.hasAccount = false,
    this.overrides = const {},
  });

  final String employeeId;
  final String? code;
  final String? fullName;
  final String? positionName;
  final bool departmentManager;

  /// 未开通登录账号的员工没有 user_id，暂无法授权。
  final bool hasAccount;

  /// permissionCode → "grant"/"revoke"；未出现的 code 表示未覆盖、按基线生效。
  final Map<String, String> overrides;

  factory DepartmentStaffPermissionRow.fromJson(Map<String, dynamic> json) =>
      DepartmentStaffPermissionRow(
        employeeId: json['employeeId'] as String,
        code: json['code'] as String?,
        fullName: json['fullName'] as String?,
        positionName: json['positionName'] as String?,
        departmentManager: json['departmentManager'] as bool? ?? false,
        hasAccount: json['hasAccount'] as bool? ?? false,
        overrides: (json['overrides'] as Map? ?? const {}).map(
          (k, v) => MapEntry(k as String, v as String),
        ),
      );
}
