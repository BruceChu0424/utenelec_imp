// 模拟身份（admin「切换人」）网络模型：对应后端 ImpersonationModeResponse / ImpersonationStartResponse。
import '../../../features/auth/models/auth_session.dart';

/// 模拟目标候选（picker 用）。
class ImpersonationTarget {
  const ImpersonationTarget({
    required this.employeeId,
    required this.name,
    this.employeeCode,
    this.departmentName,
    this.positionName,
  });

  final String employeeId;
  final String name;
  final String? employeeCode;
  final String? departmentName;
  final String? positionName;

  factory ImpersonationTarget.fromJson(Map<String, dynamic> json) =>
      ImpersonationTarget(
        employeeId: json['employeeId'] as String,
        name: (json['name'] as String?) ?? '',
        employeeCode: json['employeeCode'] as String?,
        departmentName: json['departmentName'] as String?,
        positionName: json['positionName'] as String?,
      );
}

/// enter 成功：限时窗口内复用的 modeToken + 窗口秒数。
class ImpersonationModeResult {
  const ImpersonationModeResult({
    required this.modeToken,
    required this.expiresIn,
  });

  final String modeToken;
  final int expiresIn;

  factory ImpersonationModeResult.fromJson(Map<String, dynamic> json) =>
      ImpersonationModeResult(
        modeToken: json['modeToken'] as String,
        expiresIn: (json['expiresIn'] as num).toInt(),
      );
}

/// 模拟会话元数据：供前端横幅展示「正以谁的身份 / 剩余时间 / 只读」。
class ImpersonationMeta {
  const ImpersonationMeta({
    this.actorUserId,
    this.targetUserId,
    this.targetName,
    this.department,
    this.position,
    required this.windowExpiresAtEpochMs,
    required this.readOnly,
  });

  final String? actorUserId;
  final String? targetUserId;
  final String? targetName;
  final String? department;
  final String? position;
  final int windowExpiresAtEpochMs;
  final bool readOnly;

  factory ImpersonationMeta.fromJson(Map<String, dynamic> json) =>
      ImpersonationMeta(
        actorUserId: json['actorUserId'] as String?,
        targetUserId: json['targetUserId'] as String?,
        targetName: json['targetName'] as String?,
        department: json['department'] as String?,
        position: json['position'] as String?,
        windowExpiresAtEpochMs: (json['windowExpiresAtEpochMs'] as num).toInt(),
        readOnly: json['readOnly'] as bool? ?? true,
      );
}

/// start 成功：目标 token（accessToken + 目标 profile）+ 元数据。
/// 注意：模拟 token 不含 refreshToken（到期即退模拟），故不复用 AuthResult.fromJson。
class ImpersonationStartResult {
  const ImpersonationStartResult({
    required this.accessToken,
    required this.expiresIn,
    required this.user,
    required this.meta,
  });

  final String accessToken;
  final int expiresIn;
  final UserProfile user;
  final ImpersonationMeta meta;

  factory ImpersonationStartResult.fromJson(Map<String, dynamic> json) {
    final token = json['token'] as Map<String, dynamic>;
    return ImpersonationStartResult(
      accessToken: token['accessToken'] as String,
      expiresIn: (token['expiresIn'] as num).toInt(),
      user: UserProfile.fromJson(token['user'] as Map<String, dynamic>),
      meta: ImpersonationMeta.fromJson(json['meta'] as Map<String, dynamic>),
    );
  }
}
