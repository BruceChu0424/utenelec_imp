// “我的部门”安全花名册模型（对应后端 MyDepartmentRosterDto）。
// 页面权限委派 DTO 已迁至 shared/auth/page_permission_delegation_models.dart。

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
