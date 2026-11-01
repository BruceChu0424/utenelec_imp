import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/badges/badge_registry.dart';

/// 业务审核中心大类与待确认小类共用服务端徽章汇总的全队列数。
/// 已合并首次/修改确认，不再另发两次切片计数；来源未知时保留 null。
final salesOrderFinancePendingCountProvider = Provider<int?>(
  (ref) => ref.watch(badgeFactOrNullProvider(BadgeFact.salesOrderFinance)),
);
