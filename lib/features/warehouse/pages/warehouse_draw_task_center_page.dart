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
import '../providers/warehouse_count_refresh.dart';
import '../widgets/warehouse_draw_task_segment.dart';
import '../widgets/warehouse_stock_doc_segment.dart';
import '../widgets/warehouse_task_center_scaffold.dart';
import '../../../shared/badges/badge_registry.dart';

class WarehouseDrawTaskCenterPage extends ConsumerWidget {
  const WarehouseDrawTaskCenterPage({
    super.key,
    this.embedded = false,
    this.externalKeyword,
    this.externalRefreshTick,
    this.externalHeader,
  });

  /// 嵌入态：作为合并页（/warehouse/tasks）「生产领料」大类的正文，见骨架注释。
  final bool embedded;
  final String? externalKeyword;
  final int? externalRefreshTick;

  /// 宿主（合并页）的大类行：嵌入态挂进分段视图折叠头随页滚走
  /// （2026-09-24「表格完全置顶」）。
  final Widget? externalHeader;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permissions = ref.watch(currentPermissionsProvider);
    final superAdmin = ref.watch(isSuperAdminProvider);
    final canStockDocs = superAdmin || permissions.contains(Perm.stockDocView);
    if (!canStockDocs) {
      return const _NoDrawPermission();
    }
    // 待领任务 / 待确认实收的退料随徽章汇总带回(ADR-108), 汇总未到/无权为 null。
    final drawCount = ref.watch(
      badgeFactOrNullProvider(BadgeFact.productionDraw),
    );
    final returnCount = ref.watch(
      badgeFactOrNullProvider(BadgeFact.productionReturn),
    );
    return WarehouseTaskCenterScaffold(
      location: RouteName.warehouseDrawTasks,
      title: '生产领料任务中心',
      searchHint: '搜索单号 / 生产计划 / 货品 / 车间',
      segments: [
        WarehouseTaskSegmentSpec(
          value: 'pending',
          label: '待领任务',
          count: drawCount,
        ),
        const WarehouseTaskSegmentSpec(value: 'draw', label: '领料单'),
        WarehouseTaskSegmentSpec(
          value: 'wdraw',
          label: '生产退料',
          count: returnCount,
        ),
      ],
      embedded: embedded,
      externalKeyword: externalKeyword,
      externalRefreshTick: externalRefreshTick,
      externalHeader: externalHeader,
      onResume: () => invalidateWarehouseTaskCounts(ref),
      bodyBuilder: (segment, keyword, refreshTick, headerPrefix) =>
          switch (segment) {
            'pending' => WarehouseDrawTaskSegment(
              keyword: keyword,
              refreshTick: refreshTick,
              externalHeader: headerPrefix,
            ),
            // 生产领料/退料由生产链自动生成（齐套建 DRAW、报工/退料闭环），
            // 不提供手工新建入口——手工单没有计划包与执行段映射，出库链路会
            // 被台账守卫拒绝，属死路；临时性出入库请用「其它入库/其它出库」。
            'draw' => WarehouseStockDocSegment(
              docType: StockDocType.draw,
              keyword: keyword,
              refreshTick: refreshTick,
              externalHeader: headerPrefix,
            ),
            _ => WarehouseStockDocSegment(
              docType: StockDocType.wdraw,
              pendingReturnCount: returnCount,
              productionReturnRequests: true,
              keyword: keyword,
              refreshTick: refreshTick,
              externalHeader: headerPrefix,
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
