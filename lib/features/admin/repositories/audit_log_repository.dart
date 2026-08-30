// 审计日志查询仓库（持 audit_log:view 的核查人员只读）。
//
// 模仿 DioAdminRepository：注入 ApiClient，DioException 已在 ApiClient 层统一转为
// ApiException。所有查询参数都经 Dio query 传递，参数化查询由后端 Specification 处理。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/audit_log_entry.dart';
import '../models/audit_session.dart';

abstract interface class AuditLogRepository {
  /// 分页搜索审计操作人员。候选不含系统任务，以 actorId 作为选择权威。
  Future<AuditActorPage> actors({int page = 1, int size = 20, String? keyword});

  /// 按登录会话分页；服务端负责跨午夜边界和 sessionId 权威分组。
  Future<AuditSessionPage> sessions({
    required String actorId,
    required String dateFrom,
    required String dateTo,
    int page = 1,
    int size = 10,
    int? snapshotAuditId,
  });

  /// 独立会话详情页使用；支持沿用列表快照，也支持直接深链加载最新摘要。
  Future<AuditSessionSummary> sessionSummary({
    required String sessionId,
    int? snapshotAuditId,
  });

  /// 懒加载单个会话的事件；返回现有 AuditLogPage 以复用详情链路。
  Future<AuditSessionEventPage> sessionEvents({
    required String sessionId,
    int size = 20,
    String? cursorAt,
    int? cursorId,
    int? snapshotAuditId,
  });

  /// 审计日志分页查询（按 createdAt DESC）。
  ///
  /// [action] 动作前缀模糊（'export' → 所有 export_*_report）；null = 不筛。
  /// [actorAccount] 操作人账号子串模糊（不区分大小写）；null = 不筛。
  /// [dateFrom]/[dateTo] 闭区间（ISO yyyy-MM-dd）；null = 不限。
  Future<AuditLogPage> list({
    int page = 1,
    int size = 20,
    String? action,
    String? actorId,
    String? actorAccount,
    String? keyword,
    String? targetType,
    String? targetId,
    String? eventSource,
    String? requestId,
    String? operationKind,
    String? actorScope,
    bool activityOnly = true,
    int? snapshotId,
    String? riskLevel,
    String? eventCategory,
    String? outcome,
    String? dateFrom,
    String? dateTo,
  });

  Future<AuditSummary> summary({
    String? action,
    String? actorId,
    String? actorAccount,
    String? keyword,
    String? targetType,
    String? targetId,
    String? eventSource,
    String? requestId,
    String? operationKind,
    String? actorScope,
    bool activityOnly = true,
    int? snapshotId,
    String? eventCategory,
    String? dateFrom,
    String? dateTo,
  });

  /// Loads the redacted before/after payload only when an administrator opens it.
  Future<AuditLogDetail> detail(int id);
}

class DioAuditLogRepository implements AuditLogRepository {
  DioAuditLogRepository(this.api);
  final ApiClient api;

  @override
  Future<AuditActorPage> actors({
    int page = 1,
    int size = 20,
    String? keyword,
  }) async {
    final json = await api.get(
      '${ApiEndpoints.adminAuditLogs}/actors',
      query: <String, dynamic>{
        'page': page,
        'size': size,
        if (keyword != null && keyword.trim().isNotEmpty)
          'keyword': keyword.trim(),
      },
    );
    return AuditActorPage.fromJson(Map<String, dynamic>.from(json as Map));
  }

  @override
  Future<AuditSessionPage> sessions({
    required String actorId,
    required String dateFrom,
    required String dateTo,
    int page = 1,
    int size = 10,
    int? snapshotAuditId,
  }) async {
    final json = await api.get(
      '/admin/audit-sessions',
      query: <String, dynamic>{
        'actorId': actorId,
        'dateFrom': dateFrom,
        'dateTo': dateTo,
        'page': page,
        'size': size,
        'snapshotAuditId': ?snapshotAuditId,
      },
    );
    return AuditSessionPage.fromJson(Map<String, dynamic>.from(json as Map));
  }

  @override
  Future<AuditSessionSummary> sessionSummary({
    required String sessionId,
    int? snapshotAuditId,
  }) async {
    final safeSessionId = Uri.encodeComponent(sessionId.trim());
    final json = await api.get(
      '/admin/audit-sessions/$safeSessionId',
      query: <String, dynamic>{'snapshotAuditId': ?snapshotAuditId},
    );
    return AuditSessionSummary.fromJson(Map<String, dynamic>.from(json as Map));
  }

  @override
  Future<AuditSessionEventPage> sessionEvents({
    required String sessionId,
    int size = 20,
    String? cursorAt,
    int? cursorId,
    int? snapshotAuditId,
  }) async {
    final safeSessionId = Uri.encodeComponent(sessionId.trim());
    final json = await api.get(
      '/admin/audit-sessions/$safeSessionId/events',
      query: <String, dynamic>{
        'size': size,
        'cursorAt': ?cursorAt,
        'cursorId': ?cursorId,
        'snapshotAuditId': ?snapshotAuditId,
      },
    );
    return AuditSessionEventPage.fromJson(
      Map<String, dynamic>.from(json as Map),
    );
  }

  @override
  Future<AuditLogPage> list({
    int page = 1,
    int size = 20,
    String? action,
    String? actorId,
    String? actorAccount,
    String? keyword,
    String? targetType,
    String? targetId,
    String? eventSource,
    String? requestId,
    String? operationKind,
    String? actorScope,
    bool activityOnly = true,
    int? snapshotId,
    String? riskLevel,
    String? eventCategory,
    String? outcome,
    String? dateFrom,
    String? dateTo,
  }) async {
    final json = await api.get(
      ApiEndpoints.adminAuditLogs,
      query: <String, dynamic>{
        'page': page,
        'size': size,
        if (action != null && action.isNotEmpty) 'action': action,
        if (actorId != null && actorId.isNotEmpty) 'actorId': actorId,
        if (actorAccount != null && actorAccount.isNotEmpty)
          'actorAccount': actorAccount,
        if (keyword != null && keyword.trim().isNotEmpty)
          'keyword': keyword.trim(),
        if (targetType != null && targetType.trim().isNotEmpty)
          'targetType': targetType.trim(),
        if (targetId != null && targetId.trim().isNotEmpty)
          'targetId': targetId.trim(),
        if (eventSource != null && eventSource.trim().isNotEmpty)
          'eventSource': eventSource.trim(),
        if (requestId != null && requestId.trim().isNotEmpty)
          'requestId': requestId.trim(),
        if (operationKind != null && operationKind.trim().isNotEmpty)
          'operationKind': operationKind.trim(),
        if (actorScope != null && actorScope.trim().isNotEmpty)
          'actorScope': actorScope.trim(),
        'activityOnly': activityOnly,
        'snapshotId': ?snapshotId,
        if (riskLevel != null && riskLevel.isNotEmpty) 'riskLevel': riskLevel,
        if (eventCategory != null && eventCategory.isNotEmpty)
          'eventCategory': eventCategory,
        if (outcome != null && outcome.isNotEmpty) 'outcome': outcome,
        if (dateFrom != null && dateFrom.isNotEmpty) 'dateFrom': dateFrom,
        if (dateTo != null && dateTo.isNotEmpty) 'dateTo': dateTo,
      },
    );
    return AuditLogPage.fromJson(Map<String, dynamic>.from(json as Map));
  }

  @override
  Future<AuditSummary> summary({
    String? action,
    String? actorId,
    String? actorAccount,
    String? keyword,
    String? targetType,
    String? targetId,
    String? eventSource,
    String? requestId,
    String? operationKind,
    String? actorScope,
    bool activityOnly = true,
    int? snapshotId,
    String? eventCategory,
    String? dateFrom,
    String? dateTo,
  }) async {
    final json = await api.get(
      '${ApiEndpoints.adminAuditLogs}/summary',
      query: <String, dynamic>{
        if (action != null && action.isNotEmpty) 'action': action,
        if (actorId != null && actorId.isNotEmpty) 'actorId': actorId,
        if (actorAccount != null && actorAccount.isNotEmpty)
          'actorAccount': actorAccount,
        if (keyword != null && keyword.trim().isNotEmpty)
          'keyword': keyword.trim(),
        if (targetType != null && targetType.trim().isNotEmpty)
          'targetType': targetType.trim(),
        if (targetId != null && targetId.trim().isNotEmpty)
          'targetId': targetId.trim(),
        if (eventSource != null && eventSource.trim().isNotEmpty)
          'eventSource': eventSource.trim(),
        if (requestId != null && requestId.trim().isNotEmpty)
          'requestId': requestId.trim(),
        if (operationKind != null && operationKind.trim().isNotEmpty)
          'operationKind': operationKind.trim(),
        if (actorScope != null && actorScope.trim().isNotEmpty)
          'actorScope': actorScope.trim(),
        'activityOnly': activityOnly,
        'snapshotId': ?snapshotId,
        if (eventCategory != null && eventCategory.isNotEmpty)
          'eventCategory': eventCategory,
        if (dateFrom != null && dateFrom.isNotEmpty) 'dateFrom': dateFrom,
        if (dateTo != null && dateTo.isNotEmpty) 'dateTo': dateTo,
      },
    );
    return AuditSummary.fromJson(Map<String, dynamic>.from(json as Map));
  }

  @override
  Future<AuditLogDetail> detail(int id) async {
    final json = await api.get('${ApiEndpoints.adminAuditLogs}/$id');
    return AuditLogDetail.fromJson(Map<String, dynamic>.from(json as Map));
  }
}

final auditLogRepositoryProvider = Provider<AuditLogRepository>(
  (ref) => DioAuditLogRepository(ref.watch(apiClientProvider)),
);
