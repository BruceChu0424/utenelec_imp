// AI 用量看板与按人限额(ADR-164)仓储: /api/admin/ai/usage-*。
//
// 读(看板/人员详情)只要求超管+authorization:manage; 写限额另要求再认证
// (403 REAUTH_REQUIRED → 网络层弹统一密码框后自动重发一次), 本仓储不自己问密码。
// 限额保存带 rowVersion 乐观锁, 期间被别人改过服务端回 409 CONFLICT。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/ai_usage_dashboard_models.dart';

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
  Future<AiUsageDashboard> dashboard(AiUsageWindow window) async =>
      AiUsageDashboard.fromJson(
        await api.get(
          ApiEndpoints.adminAiUsageDashboard,
          query: {'window': window.wire},
        ),
      );

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
