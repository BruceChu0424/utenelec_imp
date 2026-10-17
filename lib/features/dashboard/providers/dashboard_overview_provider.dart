import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../models/dashboard_overview.dart';
import '../repositories/dashboard_overview_repository.dart';

final dashboardOverviewRepositoryProvider =
    Provider<DashboardOverviewRepository>((ref) {
      return ApiDashboardOverviewRepository(ref.watch(apiClientProvider));
    });

/// 工作台「今日概览」: 进工作台按需拉一次, 不轮询(返回工作台的重拉由「返回即刷新」决定)。
///
/// 待办数字与模块卡红徽章同源(服务端按有效功能权限及对象范围汇总, ADR-108);
/// 某个来源出错时服务端只是不出那张卡, 徽章侧保留上一次的数, 这里不再自带降级重试轮询。
final dashboardOverviewProvider =
    FutureProvider.autoDispose<DashboardOverview?>((ref) {
      final scope = ref.watch(authenticatedScopeProvider);
      ref.watch(currentPermissionsProvider);
      if (scope == null) return null;
      return ref.watch(dashboardOverviewRepositoryProvider).load();
    });
