// 审计日志查询仓库（持 audit_log:view 的核查人员只读）。
//
// 模仿 DioAdminRepository：注入 ApiClient，DioException 已在 ApiClient 层统一转为
// ApiException。所有查询参数都经 Dio query 传递，参数化查询由后端 Specification 处理。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../models/audit_log_entry.dart';

abstract interface class AuditLogRepository {
  /// 审计日志分页查询（按 createdAt DESC）。
  ///
  /// [action] 动作前缀模糊（'export' → 所有 export_*_report）；null = 不筛。
  /// [actorAccount] 操作人账号子串模糊（不区分大小写）；null = 不筛。
  /// [dateFrom]/[dateTo] 闭区间（ISO yyyy-MM-dd）；null = 不限。
  Future<PagedResult<AuditLogEntry>> list({
    int page = 1,
    int size = 20,
    String? action,
    String? actorAccount,
    String? riskLevel,
    String? eventCategory,
    String? outcome,
    String? dateFrom,
    String? dateTo,
  });

  Future<AuditSummary> summary({
    String? action,
    String? actorAccount,
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
  Future<PagedResult<AuditLogEntry>> list({
    int page = 1,
    int size = 20,
    String? action,
    String? actorAccount,
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
        if (actorAccount != null && actorAccount.isNotEmpty)
          'actorAccount': actorAccount,
        if (riskLevel != null && riskLevel.isNotEmpty) 'riskLevel': riskLevel,
        if (eventCategory != null && eventCategory.isNotEmpty)
          'eventCategory': eventCategory,
        if (outcome != null && outcome.isNotEmpty) 'outcome': outcome,
        if (dateFrom != null && dateFrom.isNotEmpty) 'dateFrom': dateFrom,
        if (dateTo != null && dateTo.isNotEmpty) 'dateTo': dateTo,
      },
    );
    return PagedResult.fromJson(json, AuditLogEntry.fromJson);
  }

  @override
  Future<AuditSummary> summary({
    String? action,
    String? actorAccount,
    String? eventCategory,
    String? dateFrom,
    String? dateTo,
  }) async {
    final json = await api.get(
      '${ApiEndpoints.adminAuditLogs}/summary',
      query: <String, dynamic>{
        if (action != null && action.isNotEmpty) 'action': action,
        if (actorAccount != null && actorAccount.isNotEmpty)
          'actorAccount': actorAccount,
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
