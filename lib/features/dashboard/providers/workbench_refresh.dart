// 工作台「返回即刷新」统一出口：全局角标/未读计数 + 工作台概览。
//
// 背景：各角标（生产待排产、采购任务、研发任务、访客审批、HR 变更审核、通知未读）
// 是全局 StateNotifier 60s 轮询；子页面（如销售订货单走完审核流程）改变了后端
// 待办，返回工作台时角标仍停在旧值，要等下一轮轮询。
//
// 用法：外壳（MainShellPage）监听 pageResumeProvider——
//   · 仅在落点为工作台时调 refreshGlobalBadges + invalidate 今日概览
//     （避免不可见刷新抢转场帧）；落点是通知 Tab 时只刷通知列表。
//     各角标立即重拉（Notifier 内部已按权限自卫：无权限直接置 0，不发请求）。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../notice/providers/notice_providers.dart';
import '../../production/providers/production_pending_provider.dart';
import '../../purchase/providers/purchase_task_count_provider.dart';
import '../../rd_task/providers/rd_task_count_provider.dart';
import '../../subcontract/providers/subcontract_task_count_provider.dart';
import '../../visitor_approval/providers/visitor_pending_count_provider.dart';
import '../../finance/providers/finance_procurement_approval_count_provider.dart';
import '../../finance/providers/sales_order_finance_confirmation_count_provider.dart';
import '../../warehouse/providers/procurement_inbound_count_providers.dart';
import '../../warehouse/providers/production_draw_count_provider.dart';
import '../../sales/providers/sales_completion_count_provider.dart';
import '../../../shared/auth/pending_review_provider.dart';
import '../../../shared/models/procurement_inbound.dart';

/// 立即重拉全部全局角标/未读计数，不等 60s 轮询。
/// 各 Notifier 内部已做权限自卫（无权限静默置 0），可无条件调用。
///
/// 除 7 个全局 StateNotifier 角标外，还失效钱流/仓库/委外那批
/// `FutureProvider.autoDispose` 计数（工作台卡片徽章聚合用）——它们只在被 watch
/// 时存活，invalidate 触发重拉，使「返回工作台」「新通知到达」时这些角标即时更新。
void refreshGlobalBadges(WidgetRef ref) {
  ref.read(productionPendingCountProvider.notifier).refresh();
  ref.read(purchaseTaskCountProvider.notifier).refresh();
  ref.read(subcontractTaskCountProvider.notifier).refresh();
  ref.read(rdTaskCountProvider.notifier).refresh();
  ref.read(visitorPendingCountProvider.notifier).refresh();
  ref.read(visitorHostPendingCountProvider.notifier).refresh();
  ref.read(pendingReviewCountProvider.notifier).refresh();
  ref.read(unreadNoticeCountProvider.notifier).refresh();
  // 钱流/仓库/委外 autoDispose 计数（工作台卡片角标聚合源）
  ref.invalidate(financeProcurementApprovalCountProvider);
  ref.invalidate(salesOrderFinanceConfirmationCountProvider);
  ref.invalidate(financeArrivalExceptionCountProvider);
  ref.invalidate(warehouseInboundExpectationCountProvider);
  ref.invalidate(warehouseArrivalExceptionCountProvider);
  ref.invalidate(warehouseProductionDrawPendingCountProvider);
  ref.invalidate(procurementInspectionPendingCountProvider);
  ref.invalidate(
    procurementArrivalReturnCountProvider(ProcurementInboundOrderType.purchase),
  );
  ref.invalidate(
    procurementArrivalReturnCountProvider(
      ProcurementInboundOrderType.subcontract,
    ),
  );
  // 销售 autoDispose 计数（订单完工提醒徽章）
  ref.invalidate(salesCompletionCountProvider);
}
