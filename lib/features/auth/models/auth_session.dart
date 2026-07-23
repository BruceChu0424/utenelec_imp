// 鉴权模型：对应后端 TokenResponse / UserProfile（/auth/login、/auth/me）。

/// 当前登录用户资料。
class UserProfile {
  const UserProfile({
    required this.id,
    required this.loginAccount,
    required this.roles,
    required this.permissions,
    required this.superAdmin,
    this.name,
    this.code,
    this.department,
    this.position,
  });

  final String id;
  final String loginAccount;
  final String? name;
  final String? code;
  final String? department;
  final String? position;
  final List<String> roles;
  final List<String> permissions;
  /// 后端 users.is_super_admin 直接透传——拥有该字段后所有权限检查短路放行，
  /// 且 UI 上"岗位/职务"自动隐藏（super admin 不设置具体 position）。
  final bool superAdmin;

  bool get isAdmin => superAdmin || roles.contains('admin');
  bool get isHr => roles.contains('hr');
  bool get canManageOrg => isAdmin || isHr;

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
        id: json['id'] as String,
        loginAccount: json['loginAccount'] as String,
        name: json['name'] as String?,
        code: json['code'] as String?,
        department: json['department'] as String?,
        position: json['position'] as String?,
        superAdmin: json['superAdmin'] as bool? ?? false,
        roles: ((json['roles'] as List<dynamic>?) ?? const []).map((e) => e as String).toList(),
        permissions:
            ((json['permissions'] as List<dynamic>?) ?? const []).map((e) => e as String).toList(),
      );
}

/// 登录/刷新返回。
class AuthResult {
  const AuthResult({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
    required this.mustChangePassword,
    required this.user,
  });

  final String accessToken;
  final String refreshToken;
  final int expiresIn;
  final bool mustChangePassword;
  final UserProfile user;

  factory AuthResult.fromJson(Map<String, dynamic> json) => AuthResult(
        accessToken: json['accessToken'] as String,
        refreshToken: json['refreshToken'] as String,
        expiresIn: (json['expiresIn'] as num?)?.toInt() ?? 900,
        mustChangePassword: json['mustChangePassword'] as bool? ?? false,
        user: UserProfile.fromJson(json['user'] as Map<String, dynamic>),
      );
}
