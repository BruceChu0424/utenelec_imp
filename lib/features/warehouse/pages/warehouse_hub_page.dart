// 仓库管理入口页（hub）—— 2026-09-01 重组：
//
// 任务中心：出库任务中心 / 入库任务中心 / 生产领料任务中心 / 品质部检查结果
//   （原「出入库单据」里的其它出库/产成品出库/其它入库/产成品进仓/领料/退料，
//   以及销售出库、委外出仓、预计到货、到货异常、拣货、产成品入库任务全部按
//   业务方向并入三张任务中心卡，卡上角标 = 各自分段待办之和）。
// 出入库单据：保留无法按方向归并的仓库内部作业与特殊单据——仓库调拨、盘点、
//   委外成品退货单、委外损耗单（采购/委外收货与出仓历史已并入对应任务中心）。
// 库存查询：即时库存唯一入口（双击货品行进库存详情 = 各仓余额 + 出入库流水；
//   原「库存余额」「出入库流水」两卡下线）+ 货架目视化清单。
// 仓库报表：明细 / 汇总（不变）。
//
// 卡片统一 UtenHubCard（徽章恒在右上角）；显隐仍走 permission_by_path 同一份
// any/all 契约（canOpen），与路由守卫一致。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/cards/uten_hub_card.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/permission_by_path.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../config/warehouse_report_config.dart';
import '../models/stock_doc.dart';
import '../providers/warehouse_count_refresh.dart';
import '../widgets/warehouse_quality_result_badge.dart';
import '../widgets/warehouse_task_center_badges.dart';

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
    // 权限门控（V305）：卡片按权限点显隐，权限管理授权后才可见。
    final perms = ref.watch(currentPermissionsProvider);
    final isSuperAdmin = ref.watch(isSuperAdminProvider);
    bool can(String code) => isSuperAdmin || perms.contains(code);
    bool canOpen(String location) {
      if (isSuperAdmin) return true;
      final requiredAny = requiredAnyPermFor(location);
      final requiredAll = requiredAllPermsFor(location);
      return (requiredAny == null || requiredAny.any(perms.contains)) &&
          requiredAll.every(perms.contains);
    }

    // 任务中心卡：三张方向任务中心 + 品质部检查结果（角标 = 内部分段待办之和）。
    final taskEntries =
        <
              ({
                IconData icon,
                String label,
                String description,
                String location,
                Widget? badge,
              })
            >[
              if (canOpen(RouteName.warehouseOutboundTasks))
                (
                  icon: Icons.outbox_outlined,
                  label: '出库任务中心',
                  description: '销售出库（拣货/交接/历史）· 委外出仓 · 其它/产成品出库（新建+历史）',
                  location: RouteName.warehouseOutboundTasks,
                  badge: const WarehouseOutboundTaskBadge(showLabel: true),
                ),
              if (canOpen(RouteName.warehouseInboundTasks))
                (
                  icon: Icons.inbox_outlined,
                  label: '入库任务中心',
                  description: '采购/委外到货与异常 · 产成品点收 · 其它入库（新建+历史）',
                  location: RouteName.warehouseInboundTasks,
                  badge: const WarehouseInboundTaskBadge(showLabel: true),
                ),
              if (canOpen(RouteName.warehouseDrawTasks))
                (
                  icon: Icons.construction_outlined,
                  label: '生产领料任务中心',
                  description: '待领任务 · 领料单（新建/历史/出库进度）· 生产退料',
                  location: RouteName.warehouseDrawTasks,
                  badge: const WarehouseDrawTaskBadge(showLabel: true),
                ),
              if (can(Perm.warehouseIqcStockInView) ||
                  can(Perm.warehouseIqcReturnView))
                (
                  icon: Icons.fact_check_outlined,
                  label: '品质部检查结果',
                  description: '跟踪等待检查、全部/部分合格待入库与不合格退回；可批量确认入库',
                  location: RouteName.warehouseQualityResults,
                  badge: const WarehouseQualityResultBadge(showLabel: true),
                ),
            ]
            .toList();

    // 出入库单据（仓库内部作业与特殊单据）：调拨/盘点 + 委外成品退货/损耗历史。
    // 其它六类原生单据与采购/委外收货出仓历史已并入三张任务中心卡。
    final stockDocumentTypes = StockDocType.values
        .where(
          (type) =>
              (type == StockDocType.transfer || type == StockDocType.check) &&
              canOpen(RoutePath.stockDocList(type.code)),
        )
        .toList(growable: false);
    final linkedDocEntries = _warehouseLinkedDocEntries
        .where((e) => can(e.$5))
        .toList();

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
        '按库位号分组，打印张贴到货架',
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
                _sectionHeader(
                  context,
                  theme,
                  l10n.hubSectionTaskCenter,
                  '按业务方向归并的待办工作台；角标为各分段待办之和。',
                ),
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
                      onTap: () => goFrom(context, e.location),
                    );
                  },
                ),
                const SizedBox(height: UtenSpacing.s20),
              ],
              _sectionHeader(
                context,
                theme,
                l10n.warehouseHubSectionDocs,
                '仓库内部作业与特殊单据：调拨、盘点、委外成品退货与损耗；'
                '出入仓执行类单据已并入任务中心，历史在对应分段查看。',
              ),
              UtenResponsiveGrid(
                itemCount: stockDocumentTypes.length + linkedDocEntries.length,
                spacing: UtenSpacing.s12,
                columns: const UtenResponsiveColumns(compact: 2, medium: 4),
                itemBuilder: (context, i, _) {
                  if (i < stockDocumentTypes.length) {
                    final t = stockDocumentTypes[i];
                    return UtenHubCard(
                      icon: iconFor(t),
                      label: _stockDocTitle(t, l10n),
                      description: _stockDocSubtitle(t, l10n),
                      onTap: () =>
                          goFrom(context, RoutePath.stockDocList(t.code)),
                    );
                  }
                  final e = linkedDocEntries[i - stockDocumentTypes.length];
                  return UtenHubCard(
                    icon: e.$1,
                    label: e.$2,
                    description: e.$3,
                    onTap: () => goFrom(context, e.$4),
                  );
                },
              ),
              const SizedBox(height: UtenSpacing.s20),
              _sectionHeader(
                context,
                theme,
                l10n.warehouseHubSectionInventory,
                l10n.warehouseHubSectionInventoryDesc,
              ),
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
              _sectionHeader(
                context,
                theme,
                l10n.warehouseHubSectionReports,
                l10n.warehouseHubSectionReportsDesc,
              ),
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

  Widget _sectionHeader(
    BuildContext context,
    ThemeData theme,
    String title,
    String description,
  ) {
    return Padding(
      padding: const EdgeInsets.only(
        left: UtenSpacing.s4,
        bottom: UtenSpacing.s8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: UtenSpacing.s4),
          Text(
            description,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
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

/// 仓库 hub 单据区保留的特殊单据入口（图标/标题/副标题/路由/所需权限点）。
/// 采购/委外收货历史与出仓历史已并入任务中心，这里只留无法按方向归并的两类。
const _warehouseLinkedDocEntries = <(IconData, String, String, String, String)>[
  (
    Icons.undo_outlined,
    '委外成品退货单',
    '回厂成品退回委外商的实物历史',
    RouteName.warehouseSubcontractFinishedReturnHistory,
    Perm.warehouseSubcontractFinishedReturnHistoryView,
  ),
  (
    Icons.delete_sweep_outlined,
    '委外损耗单',
    '实物损耗数量、重量与原因历史',
    RouteName.warehouseSubcontractWasteHistory,
    Perm.warehouseSubcontractWasteHistoryView,
  ),
];

// 出入库单据卡标题/副标题本地化（StockDocType 枚举仍是中文 label，列表/编辑页在用）。
String _stockDocTitle(StockDocType t, AppLocalizations l10n) => switch (t) {
  StockDocType.transfer => l10n.warehouseHubDocTransfer,
  StockDocType.check => l10n.warehouseHubDocCheck,
  _ => t.label,
};

String _stockDocSubtitle(StockDocType t, AppLocalizations l10n) => switch (t) {
  StockDocType.transfer => l10n.warehouseHubDocTransferSub,
  StockDocType.check => l10n.warehouseHubDocCheckSub,
  _ => '',
};

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
