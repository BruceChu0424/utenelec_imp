// 财务报表页（Phase 3）
// 文档：docs/03-页面/财务报表页.md

import 'package:flutter/material.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/ui/app_notification.dart';
import '../../../components/buttons/click_guard.dart';

class FinanceReportPage extends StatelessWidget {
  const FinanceReportPage({super.key});

  @override
  Widget build(BuildContext context) {
    final wide = context.breakpoint.atLeastMedium;

    return Scaffold(
      appBar: UtenAppBar(
        title: '财务报表',
        showBackButton: true,
        actions: [
          UtenActionButton(
            type: UtenActionButtonType.ghost,
            size: UtenActionButtonSize.small,
            icon: Icons.download_rounded,
            label: const Text('导出'),
            loadingLabel: const Text('导出中…'),
            onAction: () async {
              await Future<void>.delayed(const Duration(milliseconds: 600));
              if (context.mounted) context.appInfo('导出 Excel（Mock）');
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 筛选行
                UtenCard(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      const Text('2026年7月',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(width: 6),
                      const Text('· 全公司',
                          style: TextStyle(color: UtenColors.slate500)),
                      const Spacer(),
                      TextButton(
                        onPressed: () {},
                        child: const Text('切换'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                // KPI 矩阵（响应式列数）
                UtenResponsiveGrid(
                  itemCount: _kpi.length,
                  columns: const UtenResponsiveColumns(
                      compact: 2),
                  itemBuilder: (context, i, _) => _KpiCard(data: _kpi[i]),
                ),
                const SizedBox(height: 24),
                // 图表区（大屏并排，小屏堆叠）
                if (wide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _TrendChart()),
                      const SizedBox(width: 16),
                      Expanded(child: _CostChart()),
                    ],
                  )
                else ...[
                  _TrendChart(),
                  const SizedBox(height: 16),
                  _CostChart(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Kpi {
  const _Kpi(this.label, this.value, this.delta, this.up);
  final String label;
  final String value;
  final String delta;
  final bool up;
}

const _kpi = [
  _Kpi('报销总额', '¥45.2万', '12%', true),
  _Kpi('工资总额', '¥234万', '5%', true),
  _Kpi('部门成本', '¥260万', '3%', true),
  _Kpi('利润率', '18%', '2%', false),
];

class _KpiCard extends StatelessWidget {
  const _KpiCard({required this.data});
  final _Kpi data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final deltaColor = data.up ? UtenColors.success : UtenColors.error;
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(data.label,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          Text(data.value,
              style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()])),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(data.up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                  size: 14, color: deltaColor),
              const SizedBox(width: 2),
              Text(data.delta,
                  style: TextStyle(
                      color: deltaColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
              const SizedBox(width: 4),
              Text('环比',
                  style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant, fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }
}

class _TrendChart extends StatelessWidget {
  static const _months = ['1', '2', '3', '4', '5', '6', '7'];
  static const _values = [28, 32, 30, 38, 35, 42, 45]; // 万元

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const UtenSectionHeader(title: '报销趋势（万元）'),
          const SizedBox(height: 16),
          SizedBox(
            height: 160,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < _values.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Expanded(
                          child: FractionallySizedBox(
                            widthFactor: 0.6,
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              decoration: BoxDecoration(
                                color: UtenColors.teal500,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text('${_values[i]}',
                            style: TextStyle(
                                fontSize: 10, color: theme.colorScheme.onSurfaceVariant)),
                        Text(_months[i],
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

class _CostChart extends StatelessWidget {
  static const _data = [
    ('生产部', 96),
    ('质量部', 24),
    ('人事部', 30),
    ('财务部', 18),
    ('其他', 92),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final max = _data.map((e) => e.$2).reduce((a, b) => a > b ? a : b).toDouble();
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const UtenSectionHeader(title: '部门成本（万元）'),
          const SizedBox(height: 12),
          for (final (name, v) in _data) ...[
            Row(
              children: [
                SizedBox(
                    width: 56,
                    child: Text(name,
                        style: theme.textTheme.bodySmall)),
                const SizedBox(width: 8),
                Expanded(
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: v / max,
                    child: Container(
                      height: 14,
                      decoration: BoxDecoration(
                        color: UtenColors.teal600,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 40,
                  child: Text('$v',
                      style: theme.textTheme.bodySmall?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()])),
                ),
              ],
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}
