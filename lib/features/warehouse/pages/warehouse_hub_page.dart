// 仓库管理入口页（hub）—— 2026-09-24 模块三段式统一：
//
// 任务中心：仓库任务中心（合并页 /warehouse/tasks，出库 / 入库 / 生产领料 /
//   品质检查结果 / 委外成品退货 / 委外损耗 六大类；原四张任务中心卡与两张
//   历史只读卡收拢为一张卡，卡角标 = 模块待办累计，与顶栏药丸/工作台仓库卡同源）。
// 新建单据：仓库原生单据的直达新建入口（其它出库 / 产成品出库 / 其它入库 /
//   产成品进仓 / 调拨 / 盘点，按 stock_doc:create 门控只对能新建的人显示；
//   2026-09-24 用户口径：新建入口一律不挂徽章）。
//   领料单 / 生产退料刻意不在新建区——由生产链自动生成（齐套建 DRAW、报工/
//   退料闭环），手工单没有计划包与执行段映射，出库链路会被台账守卫拒绝；
//   临时性出入库用「其它入库/其它出库」。
// 库存查询：即时库存唯一入口（双击货品行进库存详情）+ 货架目视化清单。
// 仓库报表：明细 / 汇总（不变）。
//
// 卡片统一 UtenHubCard；显隐只走 hub_catalog 登记的落点 + 路由守卫同一份 any/all 契约
// (hubCardAllowed，ADR-109)。计数口径(准则 14-徽章与计数口径)：
//   · 任务中心卡红数 = BadgeModule.warehouse 待办累计（四任务中心 + 仓库草稿，
//     服务端徽章目录求和，页面里不做加法）；黄数 = 同容器在办累计（等待检查结果）。
//   · 新建区六张卡不挂数（新建入口不是待办；草稿仍在新页「草稿(N)」按钮与
//     任务中心各草稿分段可见）。
//   · 库存查询与报表区是浏览型入口，不挂任何计数。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_module_progress_chip.dart';
import '../../../components/feedback/uten_module_todo_chip.dart';
import '../../../components/feedback/uten_notification_badge.dart';
import '../../../components/feedback/uten_in_progress_badge.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/cards/uten_hub_card.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../config/warehouse_report_config.dart';
import '../models/stock_doc.dart';
import '../providers/warehouse_count_refresh.dart';
import '../../../shared/badges/badge_registry.dart';

class WarehouseHubPage extends ConsumerWidget {
  const WarehouseHubPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 返回即刷新：重拉任务中心各计数（角标 = 分段之和，口径与工作台仓库卡一致）。
    ref.onPageResume(
      RouteName.warehouse,
      () => invalidateWarehouseTaskCounts(ref),
    );
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    // 卡片显隐 = hub 目录登记的落点 + 路由守卫(与 /warehouse 入口守卫同源)。
    final perms = ref.watch(currentPermissionsProvider);
    final isSuperAdmin = ref.watch(isSuperAdminProvider);
    bool canOpen(String location) =>
        hubCardAllowed(RouteName.warehouse, location, perms, isSuperAdmin);

    // 任务中心卡（2026-09-24 合并）：六大类一站式；角标 = 模块待办/在办累计
    //（服务端徽章目录求和，与顶栏两枚药丸、工作台仓库卡同源同数）。
    final taskEntries =
        <
              ({
                IconData icon,
                String label,
                String description,
                String location,
                Widget? badge,
                Widget? progressBadge,
              })
            >[
              if (canOpen(RouteName.warehouseTasks))
                (
                  icon: Icons.task_alt_outlined,
                  label: '仓库任务中心',
                  description: '出库 · 入库 · 生产领料 · 品质检查结果 · 委外退回，一站式查看与办理',
                  location: RouteName.warehouseTasks,
                  badge: UtenNotificationBadge(
                    count: ref.watch(
                      badgeModuleTodoProvider(BadgeModule.warehouse),
                    ),
                    showLabel: true,
                  ),
                  // 黄 = 等待检查结果的收货单(货已收、结论在品质部手上)。
                  progressBadge: UtenInProgressBadge(
                    count: ref.watch(
                      badgeModuleInProgressProvider(BadgeModule.warehouse),
                    ),
                    showLabel: true,
                  ),
                ),
            ]
            .toList();

    // 新建单据区：仓库原生单据直达新建页（creator-only，路由守卫按
    // /warehouse/:code/new 的 create 权限放行；不支持手工新建的类型不登记）。
    final createEntries =
        <({IconData icon, String label, String description, String location})>[
          (
            icon: Icons.outbox_outlined,
            label: '新建其它出库',
            description: '临时性、非销售/委外方向的出库',
            location: RoutePath.stockDocNew(StockDocType.otherOut.code),
          ),
          (
            icon: Icons.unarchive_outlined,
            label: '新建产成品出库',
            description: '产成品出仓单',
            location: RoutePath.stockDocNew(StockDocType.finishedOut.code),
          ),
          (
            icon: Icons.inbox_outlined,
            label: '新建其它入库',
            description: '临时性、无上游单据的入库',
            location: RoutePath.stockDocNew(StockDocType.otherIn.code),
          ),
          (
            icon: Icons.archive_outlined,
            label: '新建产成品进仓',
            description: '产成品进仓单',
            location: RoutePath.stockDocNew(StockDocType.finishedIn.code),
          ),
          (
            icon: Icons.swap_horiz_outlined,
            label: '新建调拨单',
            description: '仓与仓之间的库存调拨',
            location: RoutePath.stockDocNew(StockDocType.transfer.code),
          ),
          (
            icon: Icons.fact_check_outlined,
            label: '新建盘点单',
            description: '库存盘点与盈亏调整',
            location: RoutePath.stockDocNew(StockDocType.check.code),
          ),
        ].where((e) => canOpen(e.location)).toList();

    final stockQueryEntries = <_StockQueryEntry>[
      _StockQueryEntry(
        Icons.inventory_rounded,
        l10n.warehouseHubInventoryLive,
        '按分类/仓库/关键字聚合查询；双击货品行进入库存详情（各仓余额、出入库流水、受控调整）',
        RouteName.stockInstantInventory,
      ),
      const _StockQueryEntry(
        Icons.view_agenda_outlined,
        '货架目视化清单',
        '按库行/层/位查找，打印张贴到货架',
        RouteName.warehouseShelfLabels,
      ),
    ].where((entry) => canOpen(entry.location)).toList(growable: false);

    final reportKinds = WarehouseReportKind.values
        .where((kind) => canOpen(kind.route))
        .toList(growable: false);
    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.warehouseHubTitle,
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.dashboard),
        ),
        actions: [
          // 黄药丸排在红药丸左边(与卡片右上角「黄左红右」同序): 本模块还在跑、
          // 暂不用仓库动手的合计, 求和同样只在服务端徽章目录里做一次。
          UtenModuleProgressChip(
            count: ref.watch(
              badgeModuleInProgressProvider(BadgeModule.warehouse),
            ),
          ),
          // 本模块累计：数字由注册表对 BadgeModule.warehouse 名下入口求和得出
          //（四张任务中心 + 仓库草稿），页面里不要再手写加法；0 由徽章自己不渲染。
          UtenModuleTodoChip(
            count: ref.watch(badgeModuleTodoProvider(BadgeModule.warehouse)),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: ListView(
            padding: EdgeInsets.only(
              top: UtenSpacing.s12,
              bottom: context.breakpoint.isCompact
                  ? UtenSpacing.s16
                  : UtenSpacing.s40,
            ),
            children: [
              // 任务中心：整组按权限显隐（无任何任务权限时不露空组标题）。
              if (taskEntries.isNotEmpty) ...[
                _sectionHeader(context, theme, l10n.hubSectionTaskCenter),
                UtenResponsiveGrid(
                  itemCount: taskEntries.length,
                  spacing: UtenSpacing.s12,
                  columns: const UtenResponsiveColumns(medium: 4),
                  itemBuilder: (context, index, _) {
                    final e = taskEntries[index];
                    return UtenHubCard(
                      icon: e.icon,
                      label: e.label,
                      description: e.description,
                      badge: e.badge,
                      progressBadge: e.progressBadge,
                      onTap: () => goFrom(context, e.location),
                    );
                  },
                ),
                const SizedBox(height: UtenSpacing.s20),
              ],
              // 新建单据（2026-09-24 三段式）：只对能新建的人显示（无 create
              // 权限时整组隐藏，浏览去任务中心）；新建入口一律不挂徽章。
              if (createEntries.isNotEmpty) ...[
                _sectionHeader(context, theme, '新建单据'),
                UtenResponsiveGrid(
                  itemCount: createEntries.length,
                  spacing: UtenSpacing.s12,
                  columns: const UtenResponsiveColumns(compact: 2, medium: 4),
                  itemBuilder: (context, i, _) {
                    final e = createEntries[i];
                    return UtenHubCard(
                      icon: e.icon,
                      label: e.label,
                      description: e.description,
                      onTap: () => goFrom(context, e.location),
                    );
                  },
                ),
                const SizedBox(height: UtenSpacing.s20),
              ],
              _sectionHeader(context, theme, l10n.warehouseHubSectionInventory),
              UtenResponsiveGrid(
                itemCount: stockQueryEntries.length,
                spacing: UtenSpacing.s12,
                columns: const UtenResponsiveColumns(compact: 2, medium: 4),
                itemBuilder: (context, i, _) {
                  final e = stockQueryEntries[i];
                  return UtenHubCard(
                    icon: e.icon,
                    label: e.label,
                    description: e.description,
                    onTap: () => goFrom(context, e.location),
                  );
                },
              ),
              const SizedBox(height: UtenSpacing.s20),
              _sectionHeader(context, theme, '报表中心'),
              UtenResponsiveGrid(
                itemCount: reportKinds.length,
                spacing: UtenSpacing.s12,
                columns: const UtenResponsiveColumns(compact: 2, medium: 4),
                itemBuilder: (context, i, _) {
                  final k = reportKinds[i];
                  return UtenHubCard(
                    icon: k.icon,
                    label: _warehouseReportTitle(k, l10n),
                    description: _warehouseReportSubtitle(k, l10n),
                    onTap: () => goFrom(context, k.route),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.only(
        left: UtenSpacing.s4,
        bottom: UtenSpacing.s8,
      ),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 库存查询入口（仓库管理 hub「库存查询」分区）。
class _StockQueryEntry {
  const _StockQueryEntry(
    this.icon,
    this.label,
    this.description,
    this.location,
  );
  final IconData icon;
  final String label;
  final String description;
  final String location;
}

// 出入库单据区（调拨/盘点列表 + 委外历史专页）已于 2026-09-24 三段式统一时撤下：
// 调拨/盘点改入「新建单据」区直达新建页，浏览在仓库任务中心对应大类；
// 委外成品退货单/委外损耗单历史并入任务中心大类（路由保留）。

// 仓库报表卡标题/副标题本地化（按 WarehouseReportKind 枚举查）。
String _warehouseReportTitle(WarehouseReportKind k, AppLocalizations l10n) =>
    switch (k) {
      WarehouseReportKind.detail => l10n.warehouseHubReportDetail,
      WarehouseReportKind.summary => l10n.warehouseHubReportSummary,
    };

String _warehouseReportSubtitle(WarehouseReportKind k, AppLocalizations l10n) =>
    switch (k) {
      WarehouseReportKind.detail => l10n.hubSubDetailPerItem,
      WarehouseReportKind.summary => l10n.hubSubSummaryPerDoc,
    };
