// AI 用量看板与按人限额(ADR-164)仓储: /api/admin/ai/usage-*。
//
// 读(看板/人员详情)只要求超管+authorization:manage; 写限额另要求再认证
// (403 REAUTH_REQUIRED → 网络层弹统一密码框后自动重发一次), 本仓储不自己问密码。
// 限额保存带 rowVersion 乐观锁, 期间被别人改过服务端回 409 CONFLICT。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/ai_usage_dashboard_models.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/paging/complete_paged_snapshot.dart';
import '../../../shared/paging/paged_read_intent.dart';

abstract interface class AiUsageDashboardRepository {
  /// 看板总览(指定统计窗口)。
  Future<AiUsageDashboard> dashboard(AiUsageWindow window);

  /// 人员详情(指定统计窗口); 用户不存在时服务端回 404。
  Future<AiUsagePersonDetail> person(String userId, AiUsageWindow window);

  /// 保存按人限额; [rowVersion] 为读取时的版本号, 期间被别人改过服务端回 409。
  Future<AiUserLimits> saveLimits(
    String userId, {
    required bool disabled,
    int? dailyTokenLimit,
    int? dailyJobLimit,
    required int rowVersion,
  });
}

final aiUsageDashboardRepositoryProvider = Provider<AiUsageDashboardRepository>(
  (ref) => DioAiUsageDashboardRepository(ref.watch(apiClientProvider)),
);

class DioAiUsageDashboardRepository implements AiUsageDashboardRepository {
  DioAiUsageDashboardRepository(this.api);

  final ApiClient api;

  @override
  Future<AiUsageDashboard> dashboard(AiUsageWindow window) async {
    final current = PagedReadIntent.currentRead ?? () => true;
    final rawSummary = await api.get(
      ApiEndpoints.adminAiUsageDashboard,
      query: {'window': window.wire, 'includePeople': false},
    );
    if (rawSummary['window'] != window.wire) {
      throw ApiException('INVALID_RESPONSE', '用量统计窗口未确认，请刷新后重新读取');
    }
    final summary = AiUsageDashboard.fromJson(rawSummary);
    final people = await loadCompletePagedResult<AiUsagePerson>(
      isCurrent: current,
      idOf: (row) => row.userId,
      loadPage: (page, size) async {
        final json = await api.get(
          '${ApiEndpoints.adminAiUsageDashboard}/people',
          query: {'window': window.wire, 'page': page, 'size': size},
        );
        if (json['items'] is! List ||
            [
              'page',
              'size',
              'total',
              'totalPages',
            ].any((key) => json[key] is! int)) {
          throw ApiException('INVALID_RESPONSE', '用量人员结果不完整，请刷新后重新读取');
        }
        return PagedResult.fromJson(json, AiUsagePerson.fromJson);
      },
    );
    return summary.withPeople(people.items);
  }

  @override
  Future<AiUsagePersonDetail> person(
    String userId,
    AiUsageWindow window,
  ) async => AiUsagePersonDetail.fromJson(
    await api.get(
      ApiEndpoints.adminAiUsagePerson(_checkedId(userId)),
      query: {'window': window.wire},
    ),
  );

  @override
  Future<AiUserLimits> saveLimits(
    String userId, {
    required bool disabled,
    int? dailyTokenLimit,
    int? dailyJobLimit,
    required int rowVersion,
  }) async => AiUserLimits.fromJson(
    await api.put(
      ApiEndpoints.adminAiUsagePersonLimits(_checkedId(userId)),
      body: {
        'disabled': disabled,
        'dailyTokenLimit': dailyTokenLimit,
        'dailyJobLimit': dailyJobLimit,
        'rowVersion': rowVersion,
      },
    ),
  );

  /// id 直接拼进路径: 只接受 UUID 形态。
  static String _checkedId(String id) {
    if (!RegExp(r'^[0-9A-Za-z-]{1,64}$').hasMatch(id)) {
      throw ArgumentError.value(id, 'userId', 'not a user id');
    }
    return id;
  }
}
