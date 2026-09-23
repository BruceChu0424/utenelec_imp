// 订单进度页的「完工提醒」通知自动已读。
//
// 销售待办(财务驳回 + 可分批发货)与在途订单数随工作台徽章汇总带回(ADR-108,
// salesAttention / salesOrderInFlight 入口), 这里不再单独计数; 阅读完工提醒只清通知
// 未读, 尚未开单的发货待办照常保留。

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../notice/providers/notice_providers.dart';

/// 完工类事件来源（与后端 ChainNoticeService 常量一致）。
const salesCompletionEvents = <String>[
  'PRODUCTION_FINISHED_INBOUND',
  'PRODUCTION_REPORTED',
];

/// 进入订单进度页: 完工提醒通知置已读。只在本地未读索引里确有这类未读时才发请求;
/// 失败不影响浏览, 下一轮自然对齐。
Future<void> markSalesCompletionSeen(BuildContext context) async {
  await markNoticesReadBySource(
    ProviderScope.containerOf(context, listen: false),
    salesCompletionEvents,
  );
}
