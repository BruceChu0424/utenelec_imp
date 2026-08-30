import '../../../shared/models/paged_result.dart';
import 'audit_log_entry.dart';

/// 一次成功登录建立的稳定审计会话摘要。
///
/// 会话边界、在线状态和跨午夜归属均由服务端 sessionId 权威计算；
/// 客户端不得根据相邻事件时间自行合并或拆分。
class AuditSessionSummary {
  const AuditSessionSummary({
    required this.sessionId,
    this.actorId,
    this.actorAccount,
    this.actorDepartment,
    this.actorPosition,
    this.actorDisplay,
    this.loginAt,
    this.startAction,
    this.startLabel,
    this.firstActivityAt,
    this.lastActivityAt,
    this.logoutAt,
    this.refreshExpiresAt,
    this.refreshRevokedAt,
    this.refreshCredentialStatus,
    this.refreshCredentialStatusLabel,
    this.status = 'unknown',
    this.statusLabel,
    this.operationCount = 0,
    this.eventCount = 0,
    this.successCount = 0,
    this.failureCount = 0,
    this.postLogoutCount = 0,
    this.deviceInstallationId,
    this.deviceLabel,
    this.devicePlatform,
    this.lastIp,
    this.timelinePartial = false,
    this.snapshotAuditId = 0,
  });

  final String sessionId;
  final String? actorId;
  final String? actorAccount;
  final String? actorDepartment;
  final String? actorPosition;
  final String? actorDisplay;
  final String? loginAt;
  final String? startAction;
  final String? startLabel;
  final String? firstActivityAt;
  final String? lastActivityAt;
  final String? logoutAt;
  final String? refreshExpiresAt;
  final String? refreshRevokedAt;
  final String? refreshCredentialStatus;
  final String? refreshCredentialStatusLabel;
  final String status;
  final String? statusLabel;
  final int operationCount;
  final int eventCount;
  final int successCount;
  final int failureCount;
  final int postLogoutCount;
  final String? deviceInstallationId;
  final String? deviceLabel;
  final String? devicePlatform;
  final String? lastIp;
  final bool timelinePartial;
  final int snapshotAuditId;

  factory AuditSessionSummary.fromJson(Map<String, dynamic> json) =>
      AuditSessionSummary(
        sessionId: json['sessionId'] as String? ?? '',
        actorId: json['actorId'] as String?,
        actorAccount: json['actorAccount'] as String?,
        actorDepartment: json['actorDepartment'] as String?,
        actorPosition: json['actorPosition'] as String?,
        actorDisplay: json['actorDisplay'] as String?,
        loginAt: json['loginAt'] as String?,
        startAction: json['startAction'] as String?,
        startLabel: json['startLabel'] as String?,
        firstActivityAt: json['firstActivityAt'] as String?,
        lastActivityAt: json['lastActivityAt'] as String?,
        logoutAt: json['logoutAt'] as String?,
        refreshExpiresAt: json['refreshExpiresAt'] as String?,
        refreshRevokedAt: json['refreshRevokedAt'] as String?,
        refreshCredentialStatus: json['refreshCredentialStatus'] as String?,
        refreshCredentialStatusLabel:
            json['refreshCredentialStatusLabel'] as String?,
        status: json['status'] as String? ?? 'unknown',
        statusLabel: json['statusLabel'] as String?,
        operationCount: _parseInt(json['operationCount']) ?? 0,
        eventCount: _parseInt(json['eventCount']) ?? 0,
        successCount: _parseInt(json['successCount']) ?? 0,
        failureCount: _parseInt(json['failureCount']) ?? 0,
        postLogoutCount: _parseInt(json['postLogoutCount']) ?? 0,
        deviceInstallationId: json['deviceInstallationId'] as String?,
        deviceLabel: json['deviceLabel'] as String?,
        devicePlatform: json['devicePlatform'] as String?,
        lastIp: json['lastIp'] as String?,
        timelinePartial: json['timelinePartial'] as bool? ?? false,
        snapshotAuditId: _parseInt(json['snapshotAuditId']) ?? 0,
      );

  static int? _parseInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}

class AuditSessionPage extends PagedResult<AuditSessionSummary> {
  const AuditSessionPage({
    required super.items,
    required super.page,
    required super.size,
    required super.total,
    required super.totalPages,
    required this.snapshotAuditId,
  });

  final int snapshotAuditId;

  factory AuditSessionPage.fromJson(Map<String, dynamic> json) {
    final page = AuditSessionSummary._parseInt(json['page']) ?? 1;
    final size = AuditSessionSummary._parseInt(json['size']) ?? 10;
    final total = AuditSessionSummary._parseInt(json['total']) ?? 0;
    final declaredTotalPages = AuditSessionSummary._parseInt(
      json['totalPages'],
    );
    final totalPages =
        declaredTotalPages ?? (total == 0 ? 0 : ((total + size - 1) ~/ size));
    final items = (json['items'] as List<dynamic>? ?? const [])
        .map(
          (item) => AuditSessionSummary.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .where((item) => item.sessionId.trim().isNotEmpty)
        .toList(growable: false);
    return AuditSessionPage(
      items: items,
      page: page,
      size: size,
      total: total,
      totalPages: totalPages,
      snapshotAuditId:
          AuditSessionSummary._parseInt(json['snapshotAuditId']) ?? 0,
    );
  }
}

class AuditSessionEventPage {
  const AuditSessionEventPage({
    required this.items,
    required this.hasMore,
    required this.snapshotAuditId,
    this.nextCursorAt,
    this.nextCursorId,
  });

  final List<AuditLogEntry> items;
  final String? nextCursorAt;
  final int? nextCursorId;
  final bool hasMore;
  final int snapshotAuditId;

  factory AuditSessionEventPage.fromJson(Map<String, dynamic> json) =>
      AuditSessionEventPage(
        items: (json['items'] as List<dynamic>? ?? const [])
            .map(
              (item) => AuditLogEntry.fromJson(
                Map<String, dynamic>.from(item as Map),
              ),
            )
            .toList(growable: false),
        nextCursorAt: json['nextCursorAt'] as String?,
        nextCursorId: AuditSessionSummary._parseInt(json['nextCursorId']),
        hasMore: json['hasMore'] as bool? ?? false,
        snapshotAuditId:
            AuditSessionSummary._parseInt(json['snapshotAuditId']) ?? 0,
      );
}
