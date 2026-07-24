// 经营 Dashboard 页（Phase 5）
// 文档：docs/03-页面/经营Dashboard页.md
//
// 响应式：compact 自套 UtenContentContainer 收敛（medium+ 外壳已收敛到
// 1600，不再叠加 1200 限宽）；KPI 统一为 UtenStatCard，compact 强制 2 列，
// 宽屏按容器宽度自适应 4-5 列，不再拉宽。

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/cards/uten_stat_card.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';

class BusinessDashboardPage extends StatelessWidget {
  const BusinessDashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    final wide = context.breakpoint.atLeastMedium;
    final isCompact = context.breakpoint.isCompact;

    Widget body = SingleChildScrollView(
      padding: EdgeInsets.symmetric(
        horizontal: isCompact ? 0 : UtenSpacing.s16,
        vertical: UtenSpacing.s16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // KPI 矩阵：手机 2 列；宽屏按容器宽度 4-5 列（网格默认规则）
          UtenResponsiveGrid(
            itemCount: _kpi.length,
            columns: isCompact ? const UtenResponsiveColumns(compact: 2) : null,
            itemBuilder: (context, i, _) => UtenStatCard(
              title: _kpi[i].label,
              value: _kpi[i].value,
              unit: _kpi[i].unit,
              icon: _kpi[i].icon,
              trend: _kpi[i].up ? UtenTrend.up : UtenTrend.down,
              trendPercent: _kpi[i].delta,
              comparisonLabel: '环比',
            ),
          ),
          const SizedBox(height: UtenSpacing.s24),
          if (wide)
            const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _RevenueChart()),
                SizedBox(width: UtenSpacing.s16),
                Expanded(child: _DeptCostChart()),
              ],
            )
          else ...[
            const _RevenueChart(),
            const SizedBox(height: UtenSpacing.s16),
            const _DeptCostChart(),
          ],
        ],
      ),
    );
    if (isCompact) body = UtenContentContainer(child: body);

    return Scaffold(
      appBar: UtenAppBar(
        title: '经营 Dashboard',
        subtitle: '全公司 · 今日',
        showBackButton: true,
        actions: [
          IconButton(
            tooltip: '异常告警',
            onPressed: () => context.go('/analytics/alerts'),
            icon: const Icon(Icons.notifications_active_rounded),
          ),
        ],
      ),
      body: body,
    );
  }
}

class _K {
  const _K(this.label, this.value, this.unit, this.delta, this.up, this.icon);
  final String label;
  final num value;
  final String unit;
  final double delta;
  final bool up;
  final IconData icon;
}

const _kpi = [
  _K('今日产量', 12800, '件', 5, true, Icons.precision_manufacturing_rounded),
  _K('本月订单', 450, '万', 12, true, Icons.shopping_cart_rounded),
  _K('部门成本', 260, '万', 3, true, Icons.savings_outlined),
  _K('利润', 190, '万', 8, true, Icons.trending_up_rounded),
  _K('在职员工', 286, '人', 2, true, Icons.people_rounded),
  _K('库存周转', 4.2, '次', 0.3, true, Icons.autorenew_rounded),
  _K('合格率', 98.5, '%', 0.5, true, Icons.verified_rounded),
  _K('设备在线', 96, '%', 2, true, Icons.hvac_rounded),
];

class _RevenueChart extends StatelessWidget {
  const _RevenueChart();
  static const _m = ['1', '2', '3', '4', '5', '6', '7'];
  static const _v = [320, 360, 340, 410, 390, 440, 450];
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const UtenSectionHeader(title: '营收趋势（万元）'),
          const SizedBox(height: UtenSpacing.s16),
          SizedBox(
            height: 160,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < _v.length; i++) ...[
                  if (i > 0) const SizedBox(width: UtenSpacing.s8),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Expanded(
                          child: FractionallySizedBox(
                            widthFactor: 0.55,
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              decoration: const BoxDecoration(
                                color: UtenColors.teal500,
                                borderRadius: UtenRadius.xsAll,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: UtenSpacing.s4),
                        Text('${_v[i]}',
                            style: TextStyle(
                                fontSize: 10, color: theme.colorScheme.onSurfaceVariant)),
                        Text(_m[i],
                            style: TextStyle(
                                fontSize: 11, color: theme.colorScheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DeptCostChart extends StatelessWidget {
  const _DeptCostChart();
  static const _d = [('生产部', 96), ('质量部', 24), ('人事部', 30), ('财务部', 18), ('其他', 92)];
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final max = _d.map((e) => e.$2).reduce((a, b) => a > b ? a : b).toDouble();
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const UtenSectionHeader(title: '部门成本（万元）'),
          const SizedBox(height: UtenSpacing.s12),
          for (final (n, v) in _d) ...[
            Row(children: [
              SizedBox(width: 56, child: Text(n, style: theme.textTheme.bodySmall)),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: v / max,
                  child: Container(
                    height: 14,
                    decoration: const BoxDecoration(
                        color: UtenColors.teal600,
                        borderRadius: UtenRadius.xsAll),
                  ),
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              SizedBox(width: 36, child: Text('$v', style: theme.textTheme.bodySmall)),
            ]),
            const SizedBox(height: UtenSpacing.s12),
          ],
        ],
      ),
    );
  }
}
