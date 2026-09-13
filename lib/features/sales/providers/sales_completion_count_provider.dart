// 销售管理与订单进度待办来自服务端未处理订单：财务驳回 + 当前可分批发货。
// 完工事件通知继续独立显示未读，进入进度页可标记已读；阅读不会消除尚未开单的发货待办。
// 每 60 秒刷新，沿 sales_order:view 和订单数据范围授权。

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

/// 完工通知未读数；通知自身使用，不叠加到销售业务待办。
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

/// 销售待办按尚未处理的订单计数：财务驳回 + 可以继续创建出货单的订单。
/// 两个阶段互斥；阅读通知不完成发货，不能清除这项待办或重复叠加通知数。
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
  final counts = await ref
      .watch(salesRepositoryProvider(SalesDocType.order))
      .progressStageCounts();
  return (counts['REJECTED'] ?? 0) + (counts['SHIPPABLE'] ?? 0);
});

/// 阅读完工消息只清通知未读；尚未处理的可发订单仍保留销售待办。
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
