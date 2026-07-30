// 审计日志列表项（GET /admin/audit-logs 的 items[]）。
//
// 对应后端 com.uten.imp.audit.AuditLogRow（只读 DTO，不含 before/after/user_agent）。
// 字段全部可空（DB 触发器行的 actor_account 可能缺；登录失败行 actor_id 为 null）。
// id 是 bigserial，JSON 序列化为 int；兼容 String 输入。
class AuditLogEntry {
  const AuditLogEntry({
    required this.id,
    this.actorId,
    this.actorAccount,
    required this.action,
    this.targetType,
    this.targetId,
    this.ip,
    this.result,
    this.createdAt,
  });

  final int id;
  final String? actorId;
  final String? actorAccount;

  /// 'export_purchase_report' / 'login' / 'login_failed' / 'change_password' /
  /// 'logout' / 触发器写入的 'insert'/'update'/'delete' 等
  final String action;
  final String? targetType;
  final String? targetId;
  final String? ip;

  /// 'success' / 'failure' / 'account_not_found' / 'bad_password' / 'reuse_detected' ...
  final String? result;

  /// ISO 8601 字符串（如 '2026-07-27T12:34:56.789+08:00'）
  final String? createdAt;

  factory AuditLogEntry.fromJson(Map<String, dynamic> json) => AuditLogEntry(
    id: _parseInt(json['id']) ?? 0,
    actorId: json['actorId'] as String?,
    actorAccount: json['actorAccount'] as String?,
    action: json['action'] as String? ?? '',
    targetType: json['targetType'] as String?,
    targetId: json['targetId'] as String?,
    ip: json['ip'] as String?,
    result: json['result'] as String?,
    createdAt: json['createdAt'] as String?,
  );

  static int? _parseInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }
}
