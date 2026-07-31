import 'package:flutter/material.dart';

import '../../../components/cards/uten_card.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/workforce_overview.dart';

class OrganizationWorkforceOverviewCard extends StatelessWidget {
  const OrganizationWorkforceOverviewCard({
    super.key,
    required this.organizationName,
    required this.organizationLevel,
    required this.loading,
    this.overview,
    this.error,
    this.onRetry,
  });

  final String organizationName;
  final String organizationLevel;
  final bool loading;
  final WorkforceOverview? overview;
  final String? error;
  final VoidCallback? onRetry;

  bool get _isCompany => organizationLevel == '公司';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UtenCard(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: UtenRadius.mdAll,
                ),
                child: Icon(
                  _isCompany ? Icons.apartment_rounded : Icons.groups_rounded,
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(width: UtenSpacing.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _isCompany ? '公司人员概况' : '部门人员概况',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      overview == null
                          ? organizationName
                          : '$organizationName · 截至 ${overview!.asOf} · 含下级部门',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (!loading && onRetry != null)
                IconButton(
                  onPressed: onRetry,
                  tooltip: '刷新人员统计',
                  icon: const Icon(Icons.refresh_rounded),
                ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s16),
          if (loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: UtenSpacing.s24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (error != null)
            _InlineError(message: error!, onRetry: onRetry)
          else if (overview != null)
            _OverviewBody(overview: overview!),
        ],
      ),
    );
  }
}

class _OverviewBody extends StatelessWidget {
  const _OverviewBody({required this.overview});

  final WorkforceOverview overview;

  @override
  Widget build(BuildContext context) {
    final rate = overview.turnoverRatePct;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _MetricSection(
          title: '当前人员',
          metrics: [
            _Metric('在册人数', '${overview.currentEmployees}', emphasized: true),
            _Metric('正式在岗', '${overview.activeEmployees}'),
            _Metric('试用期', '${overview.probationEmployees}'),
            _Metric('休假中', '${overview.onLeaveEmployees}'),
            _Metric('直属人数', '${overview.directCurrentEmployees}'),
            _Metric('下级部门', '${overview.descendantDepartmentCount}'),
          ],
        ),
        const SizedBox(height: UtenSpacing.s16),
        _MetricSection(
          title: '近 ${overview.periodMonths} 个月人员流动',
          subtitle: '${overview.periodStart} — ${overview.asOf}',
          metrics: [
            _Metric('入职', '${overview.hiredEmployees}'),
            _Metric('复职', '${overview.rehiredEmployees}'),
            _Metric('离职', '${overview.departedEmployees}'),
            _Metric(
              '净变化',
              overview.netChange > 0
                  ? '+${overview.netChange}'
                  : '${overview.netChange}',
            ),
            _Metric(
              '离职率（估算）',
              rate == null ? '—' : '${rate.toStringAsFixed(1)}%',
              tooltip: overview.historyCoverageComplete
                  ? '离职事件数 ÷ 期初与期末平均在册人数'
                  : '任职历史覆盖不完整，暂不显示离职率',
            ),
            _Metric(
              '跨部门调动',
              '${overview.transferInEmployees} 入 / '
                  '${overview.transferOutEmployees} 出',
            ),
          ],
        ),
        const SizedBox(height: UtenSpacing.s16),
        _MetricSection(
          title: '到期与未来 30 天提醒',
          metrics: [
            _Metric('合同已逾期', '${overview.contractOverdue}'),
            _Metric('合同到期', '${overview.contractExpiringIn30Days}'),
            _Metric('试用期已逾期', '${overview.probationOverdue}'),
            _Metric('试用期结束', '${overview.probationEndingIn30Days}'),
          ],
        ),
        const SizedBox(height: UtenSpacing.s12),
        _DataQualityNote(overview: overview),
      ],
    );
  }
}

class _MetricSection extends StatelessWidget {
  const _MetricSection({
    required this.title,
    required this.metrics,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final List<_Metric> metrics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              title,
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(width: UtenSpacing.s8),
              Flexible(
                child: Text(
                  subtitle!,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: UtenSpacing.s8),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 900
                ? 6
                : constraints.maxWidth >= 620
                ? 3
                : 2;
            const gap = UtenSpacing.s8;
            final width =
                (constraints.maxWidth - (columns - 1) * gap) / columns;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final metric in metrics)
                  SizedBox(
                    width: width,
                    child: _MetricTile(metric: metric),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _Metric {
  const _Metric(
    this.label,
    this.value, {
    this.emphasized = false,
    this.tooltip,
  });

  final String label;
  final String value;
  final bool emphasized;
  final String? tooltip;
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({required this.metric});

  final _Metric metric;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tile = Semantics(
      label: '${metric.label} ${metric.value}',
      child: Container(
        constraints: const BoxConstraints(minHeight: 76),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: metric.emphasized
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerLow,
          borderRadius: UtenRadius.mdAll,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              metric.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: metric.emphasized
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              metric.value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: metric.emphasized
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
    return metric.tooltip == null
        ? tile
        : Tooltip(message: metric.tooltip!, child: tile);
  }
}

class _DataQualityNote extends StatelessWidget {
  const _DataQualityNote({required this.overview});

  final WorkforceOverview overview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final incomplete = !overview.historyCoverageComplete;
    final color = incomplete
        ? theme.colorScheme.error
        : theme.colorScheme.primary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: UtenRadius.mdAll,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            incomplete
                ? Icons.warning_amber_rounded
                : Icons.info_outline_rounded,
            size: 18,
            color: color,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              overview.dataQualityNote,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: UtenRadius.mdAll,
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: theme.colorScheme.error),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(child: Text(message)),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
