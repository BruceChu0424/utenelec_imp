// 销售订单「完工提醒」未读徽章计数：复用通知系统，按 notices.source_event 过滤未读完工通知数。
//
// 完工事件来源（与后端 ChainNoticeService 常量一致）：
//   PRODUCTION_FINISHED_INBOUND（成品入库审核可发货）/ PRODUCTION_REPORTED（报工审核累计完工）
// 销售每完成一个产品 → 后端 ChainNoticeService 经 outbox 投一条 workflow 通知给订单归属销售，
// source_event 落在 notices；本 provider 数其未读数 = 徽章。销售点开订单进度页 → markSalesCompletionSeen
// 把这批通知标记已读 → 徽章归零（已读语义），并联动全局未读角标与工作台「销售管理」卡。
//
// 60s 自轮询；sales_order:view 自卫（非销售/超管不拉取）。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../../notice/providers/notice_providers.dart';
import '../models/sales_doc.dart';
import '../repositories/sales_repository.dart';

/// 完工类事件来源（与后端 ChainNoticeService 常量一致）。
const salesCompletionEvents = <String>[
  'PRODUCTION_FINISHED_INBOUND',
  'PRODUCTION_REPORTED',
];

const _pollInterval = Duration(seconds: 60);

/// 销售订单完工提醒未读数（工作台「销售管理」卡 / 销售 hub「订单进度查询」卡徽章用）。
final salesCompletionCountProvider = FutureProvider.autoDispose<int>((
  ref,
) async {
  if (!ref.watch(currentPermissionsProvider).contains(Perm.salesOrderView) &&
      !ref.watch(isSuperAdminProvider)) {
    return 0;
  }
  final timer = Timer(_pollInterval, ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return ref
      .watch(noticeRepositoryProvider)
      .unreadCountBySource(salesCompletionEvents);
});

/// 销售需要关注的总数：未解决的财务驳回订单 + 未读完工通知。
///
/// 驳回数取订单进度聚合的 `REJECTED` 桶，天然沿用订单负责人/数据范围；完工数沿用
/// 通知接收人快照。工作台「销售管理」与销售 Hub「订单进度查询」必须共用本口径。
// 徽章计数 provider 一律**常驻**（不 autoDispose）——2026-09-11 用户反馈：
// 仓库/品质的徽章「进页面要等一会才出现」「冒出来又消失又冒出来」，而采购点进去就有。
// 差别不在后端快慢，在生命周期：采购是常驻 StateNotifier，这些是 autoDispose，
// 离开页面即销毁、回来从零 loading，而 todo_badge_registry 把 loading 记成 0。
// 常驻后 invalidateSelf 刷新期间 AsyncValue 会带住旧值（见 registry 的 valueOrNull），
// 徽章不再闪；没人看时定时器不再续期，也不会空转发请求。
final salesAttentionCountProvider = FutureProvider<int>((ref) async {
  if (!ref.watch(currentPermissionsProvider).contains(Perm.salesOrderView) &&
      !ref.watch(isSuperAdminProvider)) {
    return 0;
  }
  final timer = Timer(_pollInterval, ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  var completionUnread = 0;
  var rejectedOrders = 0;
  await Future.wait<void>([
    () async {
      try {
        completionUnread = await ref
            .watch(noticeRepositoryProvider)
            .unreadCountBySource(salesCompletionEvents);
      } catch (_) {
        // 进度通知暂时不可用时仍保留未解决驳回角标。
      }
    }(),
    () async {
      try {
        final counts = await ref
            .watch(salesRepositoryProvider(SalesDocType.order))
            .progressStageCounts();
        rejectedOrders = counts['REJECTED'] ?? 0;
      } catch (_) {
        // 订单聚合暂时不可用时仍保留完工消息角标。
      }
    }(),
  ]);
  return completionUnread + rejectedOrders;
});

/// 打开订单进度页时调用：把这批完工通知标记已读，徽章归零并联动全局未读角标。
Future<void> markSalesCompletionSeen(WidgetRef ref) async {
  try {
    await ref
        .read(noticeRepositoryProvider)
        .markReadBySource(salesCompletionEvents);
  } catch (_) {
    // 标记失败不影响浏览；下次轮询仍会显示。
  }
  ref.invalidate(salesCompletionCountProvider);
  ref.invalidate(salesAttentionCountProvider);
  ref.read(unreadNoticeCountProvider.notifier).refresh();
}
