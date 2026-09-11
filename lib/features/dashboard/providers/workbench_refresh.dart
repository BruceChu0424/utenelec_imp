// 工作台全局刷新出口：全局角标/未读计数 + 工作台概览。
//
// 背景：各角标（生产待排产、车间任务、采购/委外/研发任务、访客审批、HR 变更审核、
// HR 任务中心、通知未读）是全局 StateNotifier 60s 轮询；子页面（如销售订货单走完
// 审核流程）改变了后端待办，返回工作台时角标仍停在旧值，要等下一轮轮询。
//
// 两个出口：
//   · refreshGlobalBadges ——「返回即刷新」：外壳（MainShellPage）监听 pageResumeProvider，
//     仅在落点为工作台时调用 + invalidate 今日概览（避免不可见刷新抢转场帧）；
//     落点是通知 Tab 时只刷通知列表。各角标立即重拉（Notifier 内部已按权限自卫：
//     无权限直接置 0，不发请求）。
//   · rehydrateGlobalState ——「新会话重建」：SessionRehydrateGate 在 session
//     未登录→已登录（含清空业务数据后的重新登录）时调用；推进 sessionEpoch 让接入的
//     全局 Notifier 从零重建并立即重拉（不是在旧实例上 refresh），并失效工作台概览/
//     通知列表缓存。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../notice/providers/notice_providers.dart';
import '../../production/providers/production_pending_provider.dart';
import '../../production/providers/production_workshop_task_count_provider.dart';
import '../../purchase/providers/purchase_task_count_provider.dart';
import '../../rd_task/providers/rd_task_count_provider.dart';
import '../../subcontract/providers/subcontract_task_count_provider.dart';
import '../../visitor_approval/providers/visitor_pending_count_provider.dart';
import '../../hr_task/providers/hr_task_count_provider.dart';
import '../../../shared/badges/todo_badge_registry.dart';
import '../../../shared/providers/draft_counts_provider.dart';
import '../../warehouse/providers/procurement_inbound_count_providers.dart';
import '../../warehouse/providers/warehouse_quality_result_count_provider.dart';
import '../../../shared/auth/pending_review_provider.dart';
import '../../../shared/auth/session_epoch_provider.dart';
import 'dashboard_overview_provider.dart';

/// 立即重拉全部全局角标/未读计数，不等 60s 轮询。
/// 各 Notifier 内部已做权限自卫（无权限静默置 0），可无条件调用。
///
/// 除 10 个全局 StateNotifier 角标外，还失效钱流/仓库/委外/销售那批
/// `FutureProvider.autoDispose` 计数（见 [invalidateWorkbenchBadgeCaches]）。
void refreshGlobalBadges(WidgetRef ref) {
  ref.read(productionPendingCountProvider.notifier).refresh();
  ref.read(productionWorkshopTaskCountProvider.notifier).refresh();
  ref.read(purchaseTaskCountProvider.notifier).refresh();
  ref.read(subcontractTaskCountProvider.notifier).refresh();
  ref.read(rdTaskCountProvider.notifier).refresh();
  ref.read(visitorPendingCountProvider.notifier).refresh();
  ref.read(visitorHostPendingCountProvider.notifier).refresh();
  ref.read(pendingReviewCountProvider.notifier).refresh();
  ref.read(unreadNoticeCountProvider.notifier).refresh();
  // HR 任务中心角标（工作台徽章聚合 module_badge_sum 在用；此前漏在清单外）
  ref.read(hrTaskCountProvider.notifier).refresh();
  invalidateWorkbenchBadgeCaches(ref);
}

/// 钱流/仓库/委外/销售那批 `FutureProvider.autoDispose` 计数（工作台卡片徽章聚合源）：
/// 它们只在被 watch 时存活，invalidate 触发重拉，使「返回工作台」「新通知到达」
/// 「新会话建立」时这些角标即时更新；未存活时 invalidate 是空操作。
void invalidateWorkbenchBadgeCaches(WidgetRef ref) {
  // 跨模块草稿计数（hub 单据卡「草稿(N)」与新建页草稿按钮同源，2026-09-11）：
  // 浏览型计数，卡上要新鲜，但按徽章口径不进「待办总数」累加。
  ref.invalidate(draftCountsProvider);
  // 全部待办计数源：登记在 lib/shared/badges/todo_badge_registry.dart，
  // 与模块卡/Tab 总数同一张表——新增入口只改注册表，这里不再逐个点名。
  invalidateTodoBadgeCaches(ref);
  // 仅用于 hub 内分型展示、未登记进待办累加的切片计数。
  ref.invalidate(warehouseInboundExpectationTypeCountsProvider);
  ref.invalidate(warehouseQualityResultTypeCountsProvider);
}

/// 新会话建立（未登录→已登录，含清空业务数据后的重新登录）时的全局状态重建。
///
/// 推进 [sessionEpochProvider]：所有在 provider 构造里 `ref.watch(sessionEpochProvider)`
/// 的全局角标 Notifier 被 Riverpod 释放并重建为 0、立即重拉——旧实例（含其 60s
/// 轮询与迟到响应）随之作废，新会话永远看不到上个会话的值，且无需在此逐一点名。
/// 同时失效工作台概览 / 通知列表与卡片徽章聚合的 autoDispose 缓存（未存活时为空操作）。
void rehydrateGlobalState(WidgetRef ref) {
  ref.read(sessionEpochProvider.notifier).state++;
  ref.invalidate(dashboardOverviewProvider);
  ref.invalidate(noticeListProvider);
  invalidateWorkbenchBadgeCaches(ref);
  // productionPendingCountProvider / productionWorkshopTaskCountProvider 已各自 watch
  // sessionEpoch / 会话身份，纪元推进即从零重建，无需在此点名。
}
