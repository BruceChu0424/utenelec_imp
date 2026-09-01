// 生产领料任务中心（/warehouse/tasks/draw）——领退料一站式工作台。
//
// 大类分段：待领任务（履约备料/领取队列，双击进领料单办理分批出库）｜领料单
// （新建领料单 + 历史，含出库进度分段）｜生产退料（新建退料单 + 历史）。
// 徽章口径：只挂真实待办——「待领任务」= 履约待领（open_qty>0）数；
// 领料单 / 生产退料只有草稿与历史（草稿不计入待办数）不挂。进页面不预选大类
//（未选时显示引导空态）。角标与 hub「生产领料任务中心」卡/工作台仓库卡同口径。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/router/route_names.dart';
import '../../../shared/auth/permissions.dart';
import '../models/stock_doc.dart';
import '../providers/production_draw_count_provider.dart';
import '../providers/warehouse_count_refresh.dart';
import '../widgets/warehouse_draw_task_segment.dart';
import '../widgets/warehouse_stock_doc_segment.dart';
import '../widgets/warehouse_task_center_scaffold.dart';

class WarehouseDrawTaskCenterPage extends ConsumerWidget {
  const WarehouseDrawTaskCenterPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permissions = ref.watch(currentPermissionsProvider);
    final superAdmin = ref.watch(isSuperAdminProvider);
    final canStockDocs = superAdmin || permissions.contains(Perm.stockDocView);
    if (!canStockDocs) {
      return const _NoDrawPermission();
    }
    final draw = ref.watch(warehouseProductionDrawPendingCountProvider);
    return WarehouseTaskCenterScaffold(
      location: RouteName.warehouseDrawTasks,
      title: '生产领料任务中心',
      subtitle: '待领任务 · 领料单 · 生产退料一站式办理',
      searchHint: '搜索单号 / 生产计划 / 货品 / 车间',
      segments: [
        WarehouseTaskSegmentSpec(
          value: 'pending',
          label: '待领任务',
          count: draw.isLoading ? null : draw.valueOrNull,
        ),
        const WarehouseTaskSegmentSpec(value: 'draw', label: '领料单'),
        const WarehouseTaskSegmentSpec(value: 'wdraw', label: '生产退料'),
      ],
      onResume: () => invalidateWarehouseTaskCounts(ref),
      bodyBuilder: (segment, keyword, refreshTick) => switch (segment) {
        'pending' => WarehouseDrawTaskSegment(
          keyword: keyword,
          refreshTick: refreshTick,
        ),
        'draw' => WarehouseStockDocSegment(
          docType: StockDocType.draw,
          keyword: keyword,
          refreshTick: refreshTick,
          createLabel: '新建领料单',
        ),
        _ => WarehouseStockDocSegment(
          docType: StockDocType.wdraw,
          keyword: keyword,
          refreshTick: refreshTick,
          createLabel: '新建退料单',
        ),
      },
    );
  }
}

class _NoDrawPermission extends StatelessWidget {
  const _NoDrawPermission();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('生产领料任务中心')),
      body: Center(
        child: Text('暂无库存单据查看权限，请联系仓库主管开通。', style: theme.textTheme.bodyMedium),
      ),
    );
  }
}
