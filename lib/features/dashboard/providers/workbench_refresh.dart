// 工作台「新会话重建」出口。
//
// 全局角标与通知未读数统一由 badgeSummaryProvider 一次请求带回(ADR-108): 它绑定已登录会话
// 作用域(含会话纪元), 纪元推进即从零重建并立即重拉, 这里不再逐个点名计数 provider。
// 「返回工作台」「新通知到达」「写操作成功」都只调 refreshBadges(单飞合并, 一次请求)。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../notice/providers/notice_providers.dart';
import '../../../shared/auth/session_epoch_provider.dart';
import 'dashboard_overview_provider.dart';

/// 新会话建立（未登录→已登录，含清空业务数据后的重新登录）时的全局状态重建。
///
/// 推进 [sessionEpochProvider]：徽章汇总、页面偏好快照等按会话作用域构造的 provider
/// 从零重建并立即重拉——旧实例(含其定时器与迟到响应)随之作废，新会话永远看不到上个
/// 会话的值。同时失效工作台概览 / 通知列表缓存(未存活时为空操作)。
void rehydrateGlobalState(WidgetRef ref) {
  ref.read(sessionEpochProvider.notifier).state++;
  ref.invalidate(dashboardOverviewProvider);
  ref.invalidate(noticeListProvider);
}
