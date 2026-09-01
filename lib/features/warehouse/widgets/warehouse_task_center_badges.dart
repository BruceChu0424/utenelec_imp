// 仓库任务中心三张卡的合并角标（红色圆数字徽章，与工作台/品质任务中心同款）。
//
// 口径与品质任务中心合并角标一致：
// - 任一来源仍在加载时不展示半程合计（不把「未知」伪装成真实 0）；
// - 任一来源失败显示可辨识的异常图标；
// - 各 provider 内部按权限自卫（无权限静默 0，不发请求），未授权来源自然不参与合计。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../providers/procurement_inbound_count_providers.dart';
import '../providers/production_draw_count_provider.dart';
import '../providers/production_finished_inbound_task_count_provider.dart';
import '../providers/warehouse_sales_outbound_count_provider.dart';
import '../repositories/warehouse_subcontract_outbound_repository.dart'
    show warehouseSubcontractOutboundCountProvider;

/// 出库任务中心角标 = 销售出库待办 + 委外出仓待办（草稿不计入待办数）。
class WarehouseOutboundTaskBadge extends ConsumerWidget {
  const WarehouseOutboundTaskBadge({super.key, this.showLabel = false});

  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sales = ref.watch(warehouseSalesOutboundPendingCountProvider);
    final subcontract = ref.watch(warehouseSubcontractOutboundCountProvider);
    if (sales.hasError || subcontract.hasError) {
      return _badgeError(context, '出库待办数量加载失败，请进入出库任务中心后重试');
    }
    if (sales.isLoading || subcontract.isLoading) {
      return const SizedBox.shrink();
    }
    return UtenNotificationBadge(
      count: (sales.valueOrNull ?? 0) + (subcontract.valueOrNull ?? 0),
      showLabel: showLabel,
    );
  }
}

/// 入库任务中心角标 = 预计到货 + 到货异常 + 产成品待点收（草稿不计入）。
class WarehouseInboundTaskBadge extends ConsumerWidget {
  const WarehouseInboundTaskBadge({super.key, this.showLabel = false});

  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expectations = ref.watch(warehouseInboundExpectationCountProvider);
    final exceptions = ref.watch(warehouseArrivalExceptionCountProvider);
    final finished = ref.watch(
      warehouseProductionFinishedInboundPendingCountProvider,
    );
    if (expectations.hasError || exceptions.hasError || finished.hasError) {
      return _badgeError(context, '入库待办数量加载失败，请进入入库任务中心后重试');
    }
    if (expectations.isLoading || exceptions.isLoading || finished.isLoading) {
      return const SizedBox.shrink();
    }
    return UtenNotificationBadge(
      count:
          (expectations.valueOrNull ?? 0) +
          (exceptions.valueOrNull ?? 0) +
          (finished.valueOrNull ?? 0),
      showLabel: showLabel,
    );
  }
}

/// 生产领料任务中心角标 = 履约待领（DRAW 剩余可领）任务数（草稿不计入）。
class WarehouseDrawTaskBadge extends ConsumerWidget {
  const WarehouseDrawTaskBadge({super.key, this.showLabel = false});

  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draw = ref.watch(warehouseProductionDrawPendingCountProvider);
    if (draw.hasError) {
      return _badgeError(context, '领料待办数量加载失败，请进入生产领料任务中心后重试');
    }
    if (draw.isLoading) return const SizedBox.shrink();
    return UtenNotificationBadge(
      count: draw.valueOrNull ?? 0,
      showLabel: showLabel,
    );
  }
}

Widget _badgeError(BuildContext context, String message) {
  return Tooltip(
    message: message,
    child: Icon(
      Icons.sync_problem_outlined,
      key: const ValueKey('warehouse-task-badge-error'),
      size: 20,
      color: Theme.of(context).colorScheme.error,
      semanticLabel: message,
    ),
  );
}
