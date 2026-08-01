// 仓库管理入口页（hub）—— 8 单据类型 tile（调拨/其它出入库/领退料/产成品进出仓/盘点）。
import 'package:flutter/material.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../config/warehouse_report_config.dart';
import '../models/stock_doc.dart';

class WarehouseHubPage extends StatelessWidget {
  const WarehouseHubPage({super.key});

  @override
  Widget build(BuildContext context) {
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
                itemCount: 1,
                spacing: UtenSpacing.s12,
                columns: const UtenResponsiveColumns(compact: 2, medium: 4),
                itemBuilder: (context, _, _) => _WarehouseTaskCenterTile(
                  onTap: () =>
                      goFrom(context, RouteName.operationsWarehouseWorkbench),
                ),
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
  const _WarehouseTaskCenterTile({required this.onTap});

  final VoidCallback onTap;

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
                child: Icon(Icons.inventory_2_outlined, color: color, size: 22),
              ),
              const SizedBox(height: UtenSpacing.s12),
              Text(
                '生产领料任务中心',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '提前备料并跟踪待领取、部分领取和已领取任务',
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
