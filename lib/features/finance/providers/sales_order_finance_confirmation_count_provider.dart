import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../repositories/sales_order_finance_confirmation_repository.dart';

/// 业务审核中心「销售订单确认 / 订单修改确认」两个队列分段各自的待办数。
///
/// 页内专用、autoDispose: 只在审核队列页打开期间存活, 不自带轮询; 队列页确认/驳回
/// 成功后失效重拉。业务审核中心卡的总数(含两个队列)随工作台徽章汇总带回(ADR-108),
/// 两个分段数不进任何徽章入口(同一批单据的两个切片, 再累加就是双计)。
final salesOrderFinanceQueueCountProvider = FutureProvider.autoDispose
    .family<int, bool>((ref, changesOnly) async {
      final permissions = ref.watch(currentPermissionsProvider);
      final allowed =
          permissions.contains(Perm.salesOrderFinanceView) ||
          ref.watch(isSuperAdminProvider);
      if (!allowed) return 0;
      return ref
          .watch(salesOrderFinanceConfirmationRepositoryProvider)
          .pendingCount(changesOnly: changesOnly);
    });
