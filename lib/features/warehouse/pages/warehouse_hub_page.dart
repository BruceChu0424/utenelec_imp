// 仓库管理入口页（hub）—— 任务中心 + 出入库单据 + 库存查询 + 仓库报表。
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
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../config/warehouse_report_config.dart';
import '../models/stock_doc.dart';
import '../providers/procurement_inbound_count_providers.dart';
import '../widgets/procurement_inbound_badges.dart';

class WarehouseHubPage extends ConsumerWidget {
  const WarehouseHubPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 返回即刷新：回到本 hub 时重拉「预计到货」「到货异常」两个任务中心计数。
    ref.onPageResume(RouteName.warehouse, () {
      ref.invalidate(warehouseInboundExpectationCountProvider);
      ref.invalidate(warehouseArrivalExceptionCountProvider);
    });
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
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
    ];
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
                itemCount: 3,
                spacing: UtenSpacing.s12,
                columns: const UtenResponsiveColumns(medium: 3),
                itemBuilder: (context, index, _) {
                  return switch (index) {
                    0 => UtenHubCard(
                      icon: Icons.local_shipping_outlined,
                      label: l10n.warehouseHubTaskExpected,
                      description: l10n.warehouseHubTaskExpectedSub,
                      badge: const WarehouseInboundExpectationBadge(
                        showLabel: true,
                      ),
                      onTap: () => goFrom(
                        context,
                        RouteName.warehouseInboundExpectations,
                      ),
                    ),
                    1 => UtenHubCard(
                      icon: Icons.warning_amber_rounded,
                      label: l10n.warehouseHubTaskException,
                      description: l10n.warehouseHubTaskExceptionSub,
                      badge: const WarehouseArrivalExceptionBadge(
                        showLabel: true,
                      ),
                      onTap: () =>
                          goFrom(context, RouteName.warehouseArrivalExceptions),
                    ),
                    _ => UtenHubCard(
                      icon: Icons.inventory_2_outlined,
                      label: l10n.warehouseHubTaskPicking,
                      description: l10n.warehouseHubTaskPickingSub,
                      onTap: () => goFrom(
                        context,
                        RouteName.operationsWarehouseWorkbench,
                      ),
                    ),
                  };
                },
              ),
              const SizedBox(height: UtenSpacing.s20),
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
                itemCount: StockDocType.values.length,
                spacing: UtenSpacing.s12,
                columns: const UtenResponsiveColumns(compact: 2, medium: 4),
                itemBuilder: (context, i, _) {
                  final t = StockDocType.values[i];
                  return UtenHubCard(
                    icon: iconFor(t),
                    label: _stockDocTitle(t, l10n),
                    description: _stockDocSubtitle(t, l10n),
                    onTap: () => goFrom(context, RoutePath.stockDocNew(t.code)),
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
                itemCount: WarehouseReportKind.values.length,
                spacing: UtenSpacing.s12,
                columns: const UtenResponsiveColumns(compact: 2, medium: 4),
                itemBuilder: (context, i, _) {
                  final k = WarehouseReportKind.values[i];
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
