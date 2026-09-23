import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/list_refresh_provider.dart';

const productionExecutionRefreshKey = 'production:execution';

/// 计划确认生效后的统一刷新: 生产执行列表置脏 + 徽章汇总重拉一次(同一帧合并成一个请求)。
///
/// 工作台概览与通知列表不在这里失效: 本端写修订号已前进, 用户回到工作台/通知页时
/// 「返回即刷新」按需重拉(ADR-108), 看不见的页面不在这一刻抢请求。
/// 只建备料子单不调用本函数。
void refreshAfterProductionPlanGenerated(WidgetRef ref) {
  bumpListRefresh(ref, productionExecutionRefreshKey);
}
