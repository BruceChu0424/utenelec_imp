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
  ref.read(unreadNoticeCountProvider.notifier).refresh();
}
