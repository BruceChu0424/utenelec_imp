// 工作台「返回即刷新」统一出口：全局角标/未读计数 + 工作台概览。
//
// 背景：各角标（生产待排产、采购任务、研发任务、访客审批、HR 变更审核、通知未读）
// 是全局 StateNotifier 60s 轮询；子页面（如销售订货单走完审核流程）改变了后端
// 待办，返回工作台时角标仍停在旧值，要等下一轮轮询。
//
// 用法：外壳（MainShellPage）监听 pageResumeProvider——
//   · 任何导航落定（从子页面返回 / 切 Tab）都调 refreshGlobalBadges，
//     各角标立即重拉（Notifier 内部已按权限自卫：无权限直接置 0，不发请求）；
//   · 落点是工作台时额外 invalidate dashboardOverviewProvider（重聚合概览）。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../notice/providers/notice_providers.dart';
import '../../production/providers/production_pending_provider.dart';
import '../../purchase/providers/purchase_task_count_provider.dart';
import '../../rd_task/providers/rd_task_count_provider.dart';
import '../../visitor_approval/providers/visitor_pending_count_provider.dart';
import '../../../shared/auth/pending_review_provider.dart';
import 'dashboard_overview_provider.dart';

/// 立即重拉全部全局角标/未读计数，不等 60s 轮询。
/// 各 Notifier 内部已做权限自卫（无权限静默置 0），可无条件调用。
void refreshGlobalBadges(WidgetRef ref) {
  ref.read(productionPendingCountProvider.notifier).refresh();
  ref.read(purchaseTaskCountProvider.notifier).refresh();
  ref.read(rdTaskCountProvider.notifier).refresh();
  ref.read(visitorPendingCountProvider.notifier).refresh();
  ref.read(visitorHostPendingCountProvider.notifier).refresh();
  ref.read(pendingReviewCountProvider.notifier).refresh();
  ref.read(unreadNoticeCountProvider.notifier).refresh();
}

/// 回到工作台时调用：角标全刷 + 今日概览/待办重聚合。
void refreshWorkbenchData(WidgetRef ref) {
  refreshGlobalBadges(ref);
  ref.invalidate(dashboardOverviewProvider);
}
