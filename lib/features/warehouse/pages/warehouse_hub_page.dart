// 仓库管理入口页（hub）—— 8 单据类型 tile（调拨/其它出入库/领退料/产成品进出仓/盘点）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
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
    final color = theme.colorScheme.primary;
    return Scaffold(
      appBar: UtenAppBar(
        title: '仓库管理',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.dashboard),
        ),
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: ListView(
            padding: const EdgeInsets.only(top: UtenSpacing.s12),
            children: [
              Padding(
                padding: const EdgeInsets.only(
                  left: UtenSpacing.s4,
                  bottom: UtenSpacing.s8,
                ),
                child: Text(
                  '任务中心',
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
                    0 => _WarehouseTaskCenterTile(
                      icon: Icons.local_shipping_outlined,
                      label: '预计到货任务中心',
                      description: '查看财务已批准的采购和委外订货，登记实际到货',
                      badge: const WarehouseInboundExpectationBadge(),
                      onTap: () => goFrom(
                        context,
                        RouteName.warehouseInboundExpectations,
                      ),
                    ),
                    1 => _WarehouseTaskCenterTile(
                      icon: Icons.warning_amber_rounded,
                      label: '到货异常任务中心',
                      description: '超量先隔离，等待财务审批后再继续入库',
                      badge: const WarehouseArrivalExceptionBadge(),
                      onTap: () =>
                          goFrom(context, RouteName.warehouseArrivalExceptions),
                    ),
                    _ => _WarehouseTaskCenterTile(
                      icon: Icons.inventory_2_outlined,
                      label: '生产领料任务中心',
                      description: '提前备料并跟踪待领取、部分领取和已领取任务',
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
                  '出入库单据',
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
                  '调拨 / 其它出入库 / 领退料 / 产成品进出仓 / 盘点',
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
                  return Material(
                    type: MaterialType.transparency,
                    borderRadius: UtenRadius.lgAll,
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () =>
                          goFrom(context, RoutePath.stockDocNew(t.code)),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          vertical: UtenSpacing.s20,
                          horizontal: UtenSpacing.s16,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface,
                          borderRadius: UtenRadius.lgAll,
                          border: Border.all(
                            color: theme.colorScheme.outlineVariant,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: color.withValues(alpha: 0.1),
                                borderRadius: UtenRadius.mdAll,
                              ),
                              child: Icon(iconFor(t), color: color, size: 22),
                            ),
                            const SizedBox(height: UtenSpacing.s12),
                            Text(
                              t.label,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
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
                  '库存查询',
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
                  '即时库存 / 库存查询 / 出入库流水',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              UtenResponsiveGrid(
                itemCount: _stockQueryEntries.length,
                spacing: UtenSpacing.s12,
                columns: const UtenResponsiveColumns(compact: 2, medium: 4),
                itemBuilder: (context, i, _) {
                  final e = _stockQueryEntries[i];
                  return Material(
                    type: MaterialType.transparency,
                    borderRadius: UtenRadius.lgAll,
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => goFrom(context, e.location),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          vertical: UtenSpacing.s20,
                          horizontal: UtenSpacing.s16,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface,
                          borderRadius: UtenRadius.lgAll,
                          border: Border.all(
                            color: theme.colorScheme.outlineVariant,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: color.withValues(alpha: 0.1),
                                borderRadius: UtenRadius.mdAll,
                              ),
                              child: Icon(e.icon, color: color, size: 22),
                            ),
                            const SizedBox(height: UtenSpacing.s12),
                            Text(
                              e.label,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
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
                  '仓库报表',
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
                  '明细报表（一行一货品）/ 汇总报表（一行一整单）',
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
                  return Material(
                    type: MaterialType.transparency,
                    borderRadius: UtenRadius.lgAll,
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => goFrom(context, k.route),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          vertical: UtenSpacing.s20,
                          horizontal: UtenSpacing.s16,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface,
                          borderRadius: UtenRadius.lgAll,
                          border: Border.all(
                            color: theme.colorScheme.outlineVariant,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: color.withValues(alpha: 0.1),
                                borderRadius: UtenRadius.mdAll,
                              ),
                              child: Icon(k.icon, color: color, size: 22),
                            ),
                            const SizedBox(height: UtenSpacing.s12),
                            Text(
                              k.label,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
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

class _WarehouseTaskCenterTile extends StatelessWidget {
  const _WarehouseTaskCenterTile({
    required this.icon,
    required this.label,
    required this.description,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final String label;
  final String description;
  final VoidCallback onTap;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    return Material(
      type: MaterialType.transparency,
      borderRadius: UtenRadius.lgAll,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            vertical: UtenSpacing.s20,
            horizontal: UtenSpacing.s16,
          ),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: UtenRadius.lgAll,
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: UtenRadius.mdAll,
                ),
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(height: UtenSpacing.s12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (badge != null) ...[
                    const SizedBox(width: UtenSpacing.s8),
                    badge!,
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text(
                description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
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
  const _StockQueryEntry(this.icon, this.label, this.location);
  final IconData icon;
  final String label;
  final String location;
}

const _stockQueryEntries = <_StockQueryEntry>[
  _StockQueryEntry(
    Icons.inventory_rounded,
    '即时库存',
    RouteName.stockInstantInventory,
  ),
  _StockQueryEntry(Icons.inventory_2_outlined, '库存查询', RouteName.stockBalance),
  _StockQueryEntry(Icons.swap_vert_rounded, '出入库流水', RouteName.stockMovement),
];
