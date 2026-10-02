import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/formatters/china_number_format.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/measurement/weight_prefs.dart';
import '../../../shared/measurement/widgets/weight_text.dart';
import '../models/instant_inventory_summary.dart';

/// 独立总览页正文。所有指标沿用同一筛选范围的服务端合计。
class InstantInventoryOverviewContent extends ConsumerWidget {
  const InstantInventoryOverviewContent({
    super.key,
    required this.summary,
    required this.scopeLabel,
    this.onAdvancedAnalysis,
    this.onRiskSelected,
    this.selectedRisk,
    this.riskDetails,
  });

  final InstantInventorySummary summary;
  final String scopeLabel;
  final VoidCallback? onAdvancedAnalysis;
  final ValueChanged<String>? onRiskSelected;
  final String? selectedRisk;
  final Widget? riskDetails;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final display = ref.watch(warehouseWeightUnitsPrefsProvider).display;
    return SingleChildScrollView(
      key: const Key('instant-inventory-overview-scroll'),
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: UtenSpacing.s12,
            runSpacing: UtenSpacing.s4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(scopeLabel, style: theme.textTheme.titleSmall),
              Text(
                '当前筛选的全部结果 · 与翻页无关',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s16),
          _OverviewMetrics(
            summary: summary,
            weight: summary.weightText(display),
            onRiskSelected: onRiskSelected,
          ),
          const SizedBox(height: UtenSpacing.s24),
          _AdaptiveColumns(
            breakpoint: 1000,
            secondFlex: 2,
            first: _AdvicePanel(
              summary: summary,
              selectedRisk: selectedRisk,
              onRiskSelected: onRiskSelected,
            ),
            second: riskDetails,
          ),
          const SizedBox(height: UtenSpacing.s24),
          _AdaptiveColumns(
            firstFlex: 3,
            secondFlex: 2,
            first: _StockStructure(summary: summary),
            second: _WeightCoverage(summary: summary),
          ),
          const SizedBox(height: UtenSpacing.s24),
          _UnitQuantities(summary: summary),
          if (onAdvancedAnalysis != null) ...[
            const SizedBox(height: UtenSpacing.s24),
            _SectionPanel(
              title: '进一步分析',
              subtitle: '周转天数 · ABC 分类 · FIFO 库龄 · 盘点建议',
              child: Wrap(
                spacing: UtenSpacing.s20,
                runSpacing: UtenSpacing.s12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('进入库存分析后，可重新选择仓库范围；这里的分类与表头筛选不会带入。'),
                  UtenButton(
                    key: const Key('inventory-overview-advanced-analysis'),
                    onPressed: onAdvancedAnalysis,
                    type: UtenButtonType.secondary,
                    icon: Icons.arrow_forward_rounded,
                    child: const Text('打开库存分析'),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: UtenSpacing.s16),
          const _CalculationNotes(),
        ],
      ),
    );
  }
}

String _number(num value) => formatChinaNumber(value, decimalDigits: 0);
String _count(int? value, {String unit = '项'}) =>
    value == null ? '未提供' : '${_number(value)} $unit';

class _AdaptiveColumns extends StatelessWidget {
  const _AdaptiveColumns({
    required this.first,
    required this.second,
    this.firstFlex = 1,
    this.secondFlex = 1,
    this.breakpoint = 840,
  });

  final Widget first;
  final Widget? second;
  final int firstFlex;
  final int secondFlex;
  final double breakpoint;

  @override
  Widget build(BuildContext context) {
    if (second == null) return first;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide =
            constraints.maxWidth >= breakpoint &&
            MediaQuery.textScalerOf(context).scale(14) <= 20;
        if (!wide) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              first,
              const SizedBox(height: UtenSpacing.s16),
              second!,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: firstFlex, child: first),
            const SizedBox(width: UtenSpacing.s20),
            Expanded(flex: secondFlex, child: second!),
          ],
        );
      },
    );
  }
}

class _OverviewMetrics extends StatelessWidget {
  const _OverviewMetrics({
    required this.summary,
    required this.weight,
    this.onRiskSelected,
  });

  final InstantInventorySummary summary;
  final String weight;
  final ValueChanged<String>? onRiskSelected;

  @override
  Widget build(BuildContext context) {
    final coverage = summary.weightCoverage;
    final negative = summary.count('negative_balance_rows');
    return LayoutBuilder(
      builder: (context, constraints) {
        final largeText = MediaQuery.textScalerOf(context).scale(14) > 20;
        final compactMetrics = constraints.maxWidth < 700 || largeText;
        final metrics = [
          _MetricCard(
            label: '合计库存重量',
            value: weight,
            valueKey: const Key('inventory-overview-weight'),
            description: '按仓库重量账汇总，≈ 为估算，未称部分不作零重量',
            icon: Icons.scale_outlined,
            emphasis: true,
            trailing: const WeightDisplayUnitButton(),
          ),
          _MetricCard(
            label: '库存项',
            value: _count(summary.totalRows),
            description: '每项为货品 × 颜色',
            icon: Icons.inventory_2_outlined,
            compact: compactMetrics,
          ),
          _MetricCard(
            label: '重量覆盖率',
            value: coverage == null
                ? '暂无覆盖率'
                : '${formatChinaNumber(coverage * 100, decimalDigits: 1)}%',
            description: '非零库存项中，已知重量的占比',
            icon: Icons.monitor_weight_outlined,
            compact: compactMetrics,
          ),
          _MetricCard(
            label: '单仓负库存',
            value: _count(negative, unit: '处'),
            description: negative == null
                ? '分析指标暂未提供'
                : negative > 0
                ? '需优先核查各仓余额'
                : '当前范围未发现负余额',
            icon: Icons.warning_amber_rounded,
            compact: compactMetrics,
            danger: (negative ?? 0) > 0,
            onTap: (negative ?? 0) > 0 && onRiskSelected != null
                ? () => onRiskSelected!('NEGATIVE_BALANCE')
                : null,
          ),
        ];
        if (constraints.maxWidth >= 1100 && !largeText) {
          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var index = 0; index < metrics.length; index++) ...[
                  if (index > 0) const SizedBox(width: UtenSpacing.s16),
                  Expanded(flex: index == 0 ? 2 : 1, child: metrics[index]),
                ],
              ],
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            metrics.first,
            const SizedBox(height: UtenSpacing.s12),
            if (constraints.maxWidth >= 700 && !largeText)
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var index = 1; index < metrics.length; index++) ...[
                      if (index > 1) const SizedBox(width: UtenSpacing.s12),
                      Expanded(child: metrics[index]),
                    ],
                  ],
                ),
              )
            else
              for (var index = 1; index < metrics.length; index++) ...[
                if (index > 1) const SizedBox(height: UtenSpacing.s12),
                metrics[index],
              ],
          ],
        );
      },
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.description,
    required this.icon,
    this.valueKey,
    this.emphasis = false,
    this.danger = false,
    this.trailing,
    this.onTap,
    this.compact = false,
  });

  final String label;
  final String value;
  final String description;
  final IconData icon;
  final Key? valueKey;
  final bool emphasis;
  final bool danger;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = danger ? scheme.error : scheme.primary;
    if (compact) {
      return Tooltip(
        message: description,
        child: UtenCard(
          borderRadius: UtenRadius.lg,
          onTap: onTap,
          child: Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: UtenSpacing.s12),
              Expanded(child: Text(label, style: theme.textTheme.labelLarge)),
              const SizedBox(width: UtenSpacing.s8),
              Flexible(
                child: Text(
                  value,
                  textAlign: TextAlign.end,
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return UtenCard(
      padding: const EdgeInsets.all(UtenSpacing.s20),
      borderRadius: UtenRadius.lg,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Wrap(
            spacing: UtenSpacing.s12,
            runSpacing: UtenSpacing.s8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Icon(icon, color: color, size: 20),
              Text(label, style: theme.textTheme.labelLarge),
              ?trailing,
            ],
          ),
          const SizedBox(height: UtenSpacing.s16),
          Text(
            value,
            key: valueKey,
            style:
                (emphasis
                        ? theme.textTheme.headlineMedium
                        : theme.textTheme.headlineSmall)
                    ?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: color,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            description,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionPanel extends StatelessWidget {
  const _SectionPanel({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => UtenCard(
    padding: const EdgeInsets.all(UtenSpacing.s20),
    borderRadius: UtenRadius.lg,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        UtenSectionHeader(title: title),
        const SizedBox(height: UtenSpacing.s4),
        Text(
          subtitle,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: UtenSpacing.s20),
        child,
      ],
    ),
  );
}

class _AdvicePanel extends StatelessWidget {
  const _AdvicePanel({
    required this.summary,
    this.selectedRisk,
    this.onRiskSelected,
  });

  final InstantInventorySummary summary;
  final String? selectedRisk;
  final ValueChanged<String>? onRiskSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final advice = summary.advice;
    return _SectionPanel(
      title: '智能处理建议',
      subtitle: '按优先级整理 · 每一项都有数据依据',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (advice.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s12),
              child: Text(summary.headline, style: theme.textTheme.titleSmall),
            ),
          for (var index = 0; index < advice.length; index++) ...[
            if (index > 0) const SizedBox(height: UtenSpacing.s12),
            _AdviceItem(
              advice: advice[index],
              selectedRisk: selectedRisk,
              onRiskSelected: onRiskSelected,
              expanded: selectedRisk == null
                  ? index == 0
                  : advice[index].attention == selectedRisk,
            ),
          ],
          const SizedBox(height: UtenSpacing.s16),
          Text(
            '规则分析 · 零库存不等于缺货。缺货预警还需匹配需求、预留量、可用库存和到货日期。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _AdviceItem extends StatelessWidget {
  const _AdviceItem({
    required this.advice,
    required this.expanded,
    this.selectedRisk,
    this.onRiskSelected,
  });

  final InventoryAdvice advice;
  final bool expanded;
  final String? selectedRisk;
  final ValueChanged<String>? onRiskSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final code = advice.attention;
    final category = switch (code) {
      'NEGATIVE_BALANCE' => '优先核查',
      'AWAITING_STOCK_IN' || 'AWAITING_INSPECTION' => '供应衔接',
      'UNKNOWN_WEIGHT' || 'MISSING_UNIT' => '数据完善',
      _ => '处理建议',
    };
    final selected = code != null && code == selectedRisk;
    final color = advice.urgent ? scheme.error : scheme.primary;
    final end = advice.message.indexOf('。');
    final basis = end < 0
        ? advice.message
        : advice.message.substring(0, end + 1);
    final recommendation = end < 0
        ? ''
        : advice.message.substring(end + 1).trim();
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s16),
      decoration: BoxDecoration(
        color: selected
            ? color.withValues(alpha: 0.06)
            : scheme.surfaceContainerLow,
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: selected ? color : scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                advice.urgent
                    ? Icons.error_outline_rounded
                    : Icons.tips_and_updates_outlined,
                size: 18,
                color: color,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  category,
                  style: theme.textTheme.labelMedium?.copyWith(color: color),
                ),
              ),
              if (selected)
                Text(
                  '正在查看',
                  style: theme.textTheme.labelSmall?.copyWith(color: color),
                ),
              if (!expanded && onRiskSelected != null && code != null)
                TextButton(
                  key: Key('inventory-risk-$code'),
                  onPressed: () => onRiskSelected!(code),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(44, 44),
                    padding: const EdgeInsets.symmetric(
                      horizontal: UtenSpacing.s8,
                      vertical: UtenSpacing.s4,
                    ),
                  ),
                  child: const Text('查看涉及货品'),
                ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text(advice.title, style: theme.textTheme.titleSmall),
          const SizedBox(height: UtenSpacing.s8),
          Text('依据：$basis', style: theme.textTheme.bodySmall),
          if (expanded && recommendation.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s6),
            Text('建议：$recommendation', style: theme.textTheme.bodySmall),
          ],
          if (expanded && onRiskSelected != null && code != null) ...[
            const SizedBox(height: UtenSpacing.s12),
            Align(
              alignment: Alignment.centerLeft,
              child: UtenButton(
                key: Key('inventory-risk-$code'),
                onPressed: () => onRiskSelected!(code),
                type: UtenButtonType.secondary,
                size: UtenButtonSize.small,
                icon: Icons.arrow_forward_rounded,
                child: const Text('查看涉及货品'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StockStructure extends StatelessWidget {
  const _StockStructure({required this.summary});
  final InstantInventorySummary summary;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final positive = summary.count('positive_stock_rows');
    final zero = summary.count('zero_stock_rows');
    final negative = summary.count('negative_stock_rows');
    final parts = [
      ('正库存', positive, scheme.primary),
      ('零库存', zero, scheme.outline),
      ('汇总负库存', negative, scheme.error),
    ];
    final hasDistribution =
        positive != null &&
        zero != null &&
        negative != null &&
        positive + zero + negative > 0;
    return _SectionPanel(
      title: '库存结构',
      subtitle: '按货品 × 颜色计数，不混加不同单位的数量',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hasDistribution) ...[
            Semantics(
              label: '正库存 $positive 项，零库存 $zero 项，汇总负库存 $negative 项',
              child: ClipRRect(
                borderRadius: UtenRadius.pillAll,
                child: SizedBox(
                  height: UtenSpacing.s12,
                  child: Row(
                    children: [
                      for (final (_, count, color) in parts)
                        if ((count ?? 0) > 0)
                          Expanded(
                            flex: count!,
                            child: ColoredBox(
                              color: color,
                              child: const SizedBox.expand(),
                            ),
                          ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: UtenSpacing.s16),
          ],
          for (final (label, count, color) in parts)
            _ValueRow(
              label,
              _count(count),
              markerColor: color,
              danger: label == '汇总负库存' && (count ?? 0) > 0,
            ),
          const Divider(height: UtenSpacing.s24),
          _ValueRow('有待检货物', _count(summary.count('pending_inspection_rows'))),
          _ValueRow('有合格待入库', _count(summary.count('pending_stock_in_rows'))),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            '零库存仅反映账面余额；待检与合格待入库是独立阶段，尚未计入库存。',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _WeightCoverage extends StatelessWidget {
  const _WeightCoverage({required this.summary});
  final InstantInventorySummary summary;

  @override
  Widget build(BuildContext context) {
    final coverage = summary.weightCoverage;
    return _SectionPanel(
      title: '重量数据质量',
      subtitle: '仅统计非零库存项，已知重量包含估算',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (coverage != null) ...[
            LinearProgressIndicator(
              value: coverage,
              minHeight: UtenSpacing.s12,
              borderRadius: UtenRadius.pillAll,
              semanticsLabel: '重量数据覆盖率',
              semanticsValue: '${(coverage * 100).toStringAsFixed(1)}%',
            ),
            const SizedBox(height: UtenSpacing.s16),
          ],
          _ValueRow('重量已知', _count(summary.count('stocked_weight_known_rows'))),
          _ValueRow(
            '其中含估算',
            _count(summary.count('stocked_weight_estimated_rows')),
          ),
          _ValueRow(
            '重量未知',
            _count(summary.count('stocked_weight_unknown_rows')),
          ),
          const Divider(height: UtenSpacing.s24),
          _ValueRow('单位未维护', _count(summary.count('missing_unit_rows'))),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            '覆盖率表示数据完整度，不代表称重准确率。未称部分不会作为零重量参与合计。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ValueRow extends StatelessWidget {
  const _ValueRow(
    this.label,
    this.value, {
    this.markerColor,
    this.danger = false,
  });
  final String label;
  final String value;
  final Color? markerColor;
  final bool danger;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (markerColor != null) ...[
          Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s6),
            child: Container(
              width: UtenSpacing.s8,
              height: UtenSpacing.s8,
              decoration: BoxDecoration(
                color: markerColor,
                borderRadius: UtenRadius.xsAll,
              ),
            ),
          ),
          const SizedBox(width: UtenSpacing.s8),
        ],
        Expanded(child: Text(label)),
        const SizedBox(width: UtenSpacing.s12),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: danger ? Theme.of(context).colorScheme.error : null,
            ),
          ),
        ),
      ],
    ),
  );
}

class _UnitQuantities extends StatelessWidget {
  const _UnitQuantities({required this.summary});
  final InstantInventorySummary summary;

  @override
  Widget build(BuildContext context) {
    final rows = summary.units;
    final formatter = NumberFormat('#,##0.####', 'zh_CN');
    String number(double? value) =>
        value == null ? '未提供' : formatter.format(value);
    final theme = Theme.of(context);
    Widget cell(
      String value, {
      bool header = false,
      bool numberCell = false,
      bool danger = false,
    }) => Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s16,
        vertical: UtenSpacing.s12,
      ),
      child: Text(
        value,
        textAlign: numberCell ? TextAlign.end : TextAlign.start,
        style:
            (header ? theme.textTheme.labelLarge : theme.textTheme.bodyMedium)
                ?.copyWith(
                  color: danger
                      ? theme.colorScheme.error
                      : header
                      ? theme.colorScheme.onSurfaceVariant
                      : null,
                  fontWeight: header || numberCell ? FontWeight.w600 : null,
                  fontFeatures: numberCell
                      ? const [FontFeature.tabularFigures()]
                      : null,
                ),
      ),
    );
    return _SectionPanel(
      title: '按单位统计',
      subtitle: '同一单位横向比较三个阶段 · 全零单位已隐藏',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (rows.isEmpty) const Text('暂无非零数量汇总'),
          if (rows.where((row) => row.missingUnit).length > 1) ...[
            const Text('未维护单位的原始分组分别列示，补全单位后再比较；这些数量不能直接相加。'),
            const SizedBox(height: UtenSpacing.s12),
          ],
          if (rows.isNotEmpty)
            LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth < 600 ||
                    MediaQuery.textScalerOf(context).scale(14) > 20) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final row in rows)
                        Container(
                          margin: const EdgeInsets.only(
                            bottom: UtenSpacing.s12,
                          ),
                          padding: const EdgeInsets.all(UtenSpacing.s16),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerLow,
                            borderRadius: UtenRadius.mdAll,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                row.unit,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  color: row.missingUnit
                                      ? theme.colorScheme.error
                                      : null,
                                ),
                              ),
                              const SizedBox(height: UtenSpacing.s8),
                              _ValueRow(
                                '库存数量',
                                number(row.quantity),
                                danger: (row.quantity ?? 0) < 0,
                              ),
                              _ValueRow(
                                '待检量',
                                number(row.pending),
                                danger: (row.pending ?? 0) < 0,
                              ),
                              _ValueRow(
                                '合格待入库',
                                number(row.pendingStockIn),
                                danger: (row.pendingStockIn ?? 0) < 0,
                              ),
                            ],
                          ),
                        ),
                    ],
                  );
                }
                return ClipRRect(
                  borderRadius: UtenRadius.mdAll,
                  child: Table(
                    columnWidths: const {
                      0: FlexColumnWidth(),
                      1: FlexColumnWidth(2),
                      2: FlexColumnWidth(2),
                      3: FlexColumnWidth(2),
                    },
                    defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                    border: TableBorder(
                      horizontalInside: BorderSide(
                        color: theme.colorScheme.outlineVariant,
                      ),
                    ),
                    children: [
                      TableRow(
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerLow,
                        ),
                        children: [
                          cell('单位', header: true),
                          cell('库存数量', header: true, numberCell: true),
                          cell('待检量', header: true, numberCell: true),
                          cell('合格待入库', header: true, numberCell: true),
                        ],
                      ),
                      for (final row in rows)
                        TableRow(
                          children: [
                            cell(row.unit, danger: row.missingUnit),
                            cell(
                              number(row.quantity),
                              numberCell: true,
                              danger: (row.quantity ?? 0) < 0,
                            ),
                            cell(
                              number(row.pending),
                              numberCell: true,
                              danger: (row.pending ?? 0) < 0,
                            ),
                            cell(
                              number(row.pendingStockIn),
                              numberCell: true,
                              danger: (row.pendingStockIn ?? 0) < 0,
                            ),
                          ],
                        ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

class _CalculationNotes extends StatelessWidget {
  const _CalculationNotes();

  @override
  Widget build(BuildContext context) => const UtenCard(
    padding: EdgeInsets.symmetric(horizontal: UtenSpacing.s20),
    borderRadius: UtenRadius.lg,
    child: ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.only(bottom: UtenSpacing.s20),
      title: Text('计算口径与分析边界'),
      children: [
        Text(
          '1. 所有合计覆盖当前分类、仓库、关键词及表头筛选的全部结果，与翻页无关。\n\n'
          '2. 库存项按货品 × 颜色计数；库存分布按汇总数量的正、零、负分类。单仓负库存另按仓库 × 货品 × 颜色检查，避免跨仓正负抵消。\n\n'
          '3. 重量覆盖率 = 已知重量的非零库存项 ÷ 全部非零库存项。已知中包含估算；覆盖率不是称重准确率。\n\n'
          '4. 数量仅在相同单位内合计；库存、待检与合格待入库独立列示，不互相相加。全为零的单位行隐藏，负数保留。\n\n'
          '5. 优先顺序：负库存核查 → 库存不大于零且合格待入库 → 库存不大于零且待检 → 补全重量与单位。同一项可能命中多条规则，不能累加成异常总数。\n\n'
          '6. 当前库存可能含不良品仓，账面库存不能直接当可用量。真实补货量需按同一需求口径计算 max(到期需求 + 安全库存 − 可用供应, 0)，并核对到货日期；本摘要尚未接入这些事实，不输出缺货预测或采购建议量。',
        ),
      ],
    ),
  );
}
