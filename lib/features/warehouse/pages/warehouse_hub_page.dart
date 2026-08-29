// 仓库管理入口页（hub）—— 任务中心 + 出入库单据（含收货历史）+ 库存查询 + 仓库报表。
// 卡片统一用 UtenHubCard（徽章恒在右上角；出入库/库存/报表 tile 无角标）。
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
import '../providers/procurement_inbound_count_providers.dart';
import '../providers/production_finished_inbound_task_count_provider.dart';
import '../providers/production_draw_count_provider.dart';
import '../widgets/procurement_inbound_badges.dart';
import '../widgets/production_finished_inbound_pending_badge.dart';
import '../widgets/production_draw_pending_badge.dart';
import '../widgets/warehouse_subcontract_outbound_badge.dart';

class WarehouseHubPage extends ConsumerWidget {
  const WarehouseHubPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 返回即刷新：重拉预计到货、到货异常和生产领料任务计数。
    ref.onPageResume(RouteName.warehouse, () {
      ref.invalidate(warehouseInboundExpectationCountProvider);
      ref.invalidate(warehouseArrivalExceptionCountProvider);
      ref.invalidate(warehouseProductionDrawPendingCountProvider);
      ref.invalidate(warehouseProductionFinishedInboundPendingCountProvider);
    });
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

    // 任务中心卡（含权限点）：预计到货 / 委外出仓 / 到货异常 / 拣货工作台。
    final taskEntries =
        <
              ({
                IconData icon,
                String label,
                String description,
                String location,
                String perm,
                Widget? badge,
              })
            >[
              (
                icon: Icons.local_shipping_outlined,
                label: l10n.warehouseHubTaskExpected,
                description: l10n.warehouseHubTaskExpectedSub,
                location: RouteName.warehouseInboundExpectations,
                perm: Perm.warehouseInboundView,
                badge: const WarehouseInboundExpectationBadge(showLabel: true),
              ),
              (
                icon: Icons.outbound_outlined,
                // TODO(l10n): 补 arb —— 委外出仓（材料发委外商加工）。
                label: '委外出仓',
                description: '材料出仓给委外商加工(订货批准后自动生成任务)',
                location: RouteName.warehouseSubcontractOutbound,
                perm: Perm.subcontractOutboundView,
                badge: const WarehouseSubcontractOutboundBadge(showLabel: true),
              ),
              (
                icon: Icons.warning_amber_rounded,
                label: l10n.warehouseHubTaskException,
                description: l10n.warehouseHubTaskExceptionSub,
                location: RouteName.warehouseArrivalExceptions,
                perm: Perm.warehouseInboundView,
                badge: const WarehouseArrivalExceptionBadge(showLabel: true),
              ),
              (
                icon: Icons.inventory_2_outlined,
                label: l10n.warehouseHubTaskPicking,
                description: l10n.warehouseHubTaskPickingSub,
                location: RouteName.operationsWarehouseWorkbench,
                perm: Perm.stockDocView,
                badge: const WarehouseProductionDrawPendingBadge(
                  showLabel: true,
                ),
              ),
              (
                icon: Icons.inventory_outlined,
                label: '产成品待点收',
                description: '查看生产/FQC形成的待点收任务；有点收权限者按实物逐行确认',
                location: RouteName.warehouseProductionFinishedInboundTasks,
                perm: Perm.stockDocView,
                badge: const WarehouseProductionFinishedInboundPendingBadge(
                  showLabel: true,
                ),
              ),
            ]
            .where((e) => can(e.perm))
            .toList();
    final stockQueryEntries = <_StockQueryEntry>[
      _StockQueryEntry(
        Icons.inventory_rounded,
        l10n.warehouseHubInventoryLive,
        l10n.warehouseHubInventoryLiveSub,
        RouteName.stockInstantInventory,
      ),
      _StockQueryEntry(
        Icons.inventory_2_outlined,
        l10n.warehouseHubInventoryBalance,
        l10n.warehouseHubInventoryBalanceSub,
        RouteName.stockBalance,
      ),
      _StockQueryEntry(
        Icons.swap_vert_rounded,
        l10n.warehouseHubInventoryMovement,
        l10n.warehouseHubInventoryMovementSub,
        RouteName.stockMovement,
      ),
      // TODO(l10n): 补 arb —— 货架目视化清单（挂牌打印/导出）。
      const _StockQueryEntry(
        Icons.view_agenda_outlined,
        '货架目视化清单',
        '按库位号分组，打印张贴到货架',
        RouteName.warehouseShelfLabels,
      ),
    ].where((entry) => canOpen(entry.location)).toList(growable: false);
    final stockDocumentTypes = StockDocType.values
        .where((type) => canOpen(RoutePath.stockDocList(type.code)))
        .toList(growable: false);
    // 采购/委外执行单历史卡（含权限点，V305 门控）。
    final linkedDocEntries = _warehouseLinkedDocEntries
        .where((e) => can(e.$5))
        .toList();
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
                Padding(
                  padding: const EdgeInsets.only(
                    left: UtenSpacing.s4,
                    bottom: UtenSpacing.s8,
                  ),
                  child: Text(
                    l10n.hubSectionTaskCenter,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
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
              Padding(
                padding: const EdgeInsets.only(
                  left: UtenSpacing.s4,
                  bottom: UtenSpacing.s4,
                ),
                child: Text(
                  l10n.warehouseHubSectionDocs,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(
                  left: UtenSpacing.s4,
                  bottom: UtenSpacing.s8,
                ),
                child: Text(
                  l10n.warehouseHubSectionDocsDesc,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              UtenResponsiveGrid(
                // 出入库单据卡进列表页（历史可查，列表内再新建）；前 9 张为仓库原生单据，
                // 后 6 张挂采购/委外执行单历史——仓库侧执行出入仓后要能回来查单，不必去采购/委外模块。
                // 委外四单（V304）：出仓/成品退/材料退/损耗的实际执行归仓库（V304 授权 SUB_WH）。
                // 权限门控（V305）：无对应 view 权限的卡片不显示。
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
              Padding(
                padding: const EdgeInsets.only(
                  left: UtenSpacing.s4,
                  bottom: UtenSpacing.s4,
                ),
                child: Text(
                  l10n.warehouseHubSectionInventory,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(
                  left: UtenSpacing.s4,
                  bottom: UtenSpacing.s8,
                ),
                child: Text(
                  l10n.warehouseHubSectionInventoryDesc,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
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
              Padding(
                padding: const EdgeInsets.only(
                  left: UtenSpacing.s4,
                  bottom: UtenSpacing.s4,
                ),
                child: Text(
                  l10n.warehouseHubSectionReports,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(
                  left: UtenSpacing.s4,
                  bottom: UtenSpacing.s8,
                ),
                child: Text(
                  l10n.warehouseHubSectionReportsDesc,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
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

/// 仓库 hub 单据区外挂的采购/委外执行单历史入口（图标/标题/副标题/路由/所需权限点）。
/// TODO(l10n): 补 arb。
const _warehouseLinkedDocEntries = <(IconData, String, String, String, String)>[
  (
    Icons.inbox_outlined,
    '采购收货单',
    '采购到货登记历史与审核',
    '/purchase/receipts',
    'purchase_receipt:view',
  ),
  (
    Icons.move_to_inbox_outlined,
    '委外进仓单',
    '委外到货登记历史与审核',
    '/subcontract/receipts',
    'subcontract_receipt:view',
  ),
  (
    Icons.outbound_outlined,
    '委外材料出仓单',
    '材料出仓给委外商的历史记录',
    '/subcontract/material-issues',
    'subcontract_material_issue:view',
  ),
  (
    Icons.undo_outlined,
    '委外成品退货单',
    '回厂成品退回委外商的历史记录',
    '/subcontract/returns',
    'subcontract_return:view',
  ),
  (
    Icons.assignment_return_outlined,
    '委外材料退货单',
    '委外商退回余料的历史记录',
    '/subcontract/material-returns',
    'subcontract_material_return:view',
  ),
  (
    Icons.delete_sweep_outlined,
    '委外损耗单',
    '加工损耗核销与扣款的历史记录',
    '/subcontract/wastes',
    'subcontract_waste:view',
  ),
];

// 出入库单据卡标题/副标题本地化（StockDocType 枚举仍是中文 label，列表/编辑页在用）。
String _stockDocTitle(StockDocType t, AppLocalizations l10n) => switch (t) {
  StockDocType.transfer => l10n.warehouseHubDocTransfer,
  StockDocType.otherIn => l10n.warehouseHubDocOtherIn,
  StockDocType.otherOut => l10n.warehouseHubDocOtherOut,
  StockDocType.draw => l10n.warehouseHubDocDraw,
  StockDocType.wdraw => l10n.warehouseHubDocWdraw,
  StockDocType.finishedIn => l10n.warehouseHubDocFinishedIn,
  StockDocType.finishedOut => l10n.warehouseHubDocFinishedOut,
  StockDocType.check => l10n.warehouseHubDocCheck,
};

String _stockDocSubtitle(StockDocType t, AppLocalizations l10n) => switch (t) {
  StockDocType.transfer => l10n.warehouseHubDocTransferSub,
  StockDocType.otherIn => l10n.warehouseHubDocOtherInSub,
  StockDocType.otherOut => l10n.warehouseHubDocOtherOutSub,
  StockDocType.draw => l10n.warehouseHubDocDrawSub,
  StockDocType.wdraw => l10n.warehouseHubDocWdrawSub,
  StockDocType.finishedIn => l10n.warehouseHubDocFinishedInSub,
  StockDocType.finishedOut => l10n.warehouseHubDocFinishedOutSub,
  StockDocType.check => l10n.warehouseHubDocCheckSub,
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
