import 'package:flutter/material.dart';

import '../../../../core/theme/uten_tokens.dart';
import '../models/finance_payable.dart';

class FinancePayablesKpiStrip extends StatelessWidget {
  const FinancePayablesKpiStrip({
    super.key,
    required this.summary,
    this.loading = false,
  });

  final FinancePayablesSummary? summary;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final primaryItems = <_KpiData>[
      _KpiData(
        '未付(本币)',
        summary?.outstandingLocal,
        Icons.account_balance_wallet_outlined,
        tone: _KpiTone.primary,
      ),
      _KpiData(
        '逾期(本币)',
        summary?.overdueLocal,
        Icons.warning_amber_rounded,
        tone: _KpiTone.danger,
      ),
      _KpiData(
        '本月到期',
        summary?.dueThisMonthLocal,
        Icons.event_available_outlined,
      ),
      _KpiData('应付(本币)', summary?.payableLocal, Icons.receipt_long_outlined),
    ];
    final detailItems = <_KpiData>[
      _KpiData('账面核销(本币)', summary?.settledBookLocal, Icons.menu_book_outlined),
      _KpiData('现金已付(本币)', summary?.paidLocal, Icons.task_alt_rounded),
      _KpiData('抵销(本币)', summary?.offsetLocal, Icons.rule_rounded),
      _KpiData(
        '汇兑差额(本币)',
        summary?.exchangeDifferenceLocal,
        Icons.currency_exchange_outlined,
      ),
      _KpiData('索赔贷项', summary?.creditLocal, Icons.price_change_outlined),
      _KpiData('供应商预付', summary?.prepaymentLocal, Icons.savings_outlined),
      _KpiData(
        '待处理超耗',
        summary?.pendingLossCases.toString(),
        Icons.gavel_outlined,
        currency: false,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final theme = Theme.of(context);
        final useHorizontalPrimary = constraints.maxWidth < 840;
        return DecoratedBox(
          key: const ValueKey('finance-payables-summary-panel'),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: UtenRadius.lgAll,
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.all(UtenSpacing.s16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.account_balance_outlined,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Expanded(
                      child: Text(
                        '本币应付概览',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      '服务端汇总口径',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s4),
                Semantics(
                  label: '应付减账面核销减抵销等于未付，现金已付与汇兑差额分列',
                  child: Text(
                    '核对恒等式：应付 − 账面核销 − 抵销 = 未付；'
                    '现金已付与汇兑差额分列。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(height: UtenSpacing.s12),
                if (useHorizontalPrimary)
                  SingleChildScrollView(
                    key: const ValueKey('finance-payables-kpi-scroll'),
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (
                          var index = 0;
                          index < primaryItems.length;
                          index++
                        ) ...[
                          SizedBox(
                            width: 188,
                            child: _PrimaryKpiTile(
                              data: primaryItems[index],
                              loading: loading,
                            ),
                          ),
                          if (index != primaryItems.length - 1)
                            const SizedBox(width: UtenSpacing.s8),
                        ],
                      ],
                    ),
                  )
                else
                  Row(
                    children: [
                      for (
                        var index = 0;
                        index < primaryItems.length;
                        index++
                      ) ...[
                        Expanded(
                          child: _PrimaryKpiTile(
                            data: primaryItems[index],
                            loading: loading,
                          ),
                        ),
                        if (index != primaryItems.length - 1)
                          const SizedBox(width: UtenSpacing.s8),
                      ],
                    ],
                  ),
                const SizedBox(height: UtenSpacing.s12),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLow,
                    borderRadius: UtenRadius.mdAll,
                  ),
                  child: SingleChildScrollView(
                    key: const ValueKey(
                      'finance-payables-secondary-kpi-scroll',
                    ),
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (
                          var index = 0;
                          index < detailItems.length;
                          index++
                        ) ...[
                          SizedBox(
                            width: 168,
                            child: _CompactKpiTile(
                              data: detailItems[index],
                              loading: loading,
                            ),
                          ),
                          if (index != detailItems.length - 1)
                            SizedBox(
                              height: 40,
                              child: VerticalDivider(
                                width: 1,
                                color: theme.colorScheme.outlineVariant,
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _PrimaryKpiTile extends StatelessWidget {
  const _PrimaryKpiTile({required this.data, required this.loading});

  final _KpiData data;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = _displayValue(data, loading);
    final (background, foreground) = switch (data.tone) {
      _KpiTone.primary => (
        theme.colorScheme.primaryContainer.withValues(alpha: 0.45),
        theme.colorScheme.onPrimaryContainer,
      ),
      _KpiTone.danger => (
        theme.colorScheme.errorContainer.withValues(alpha: 0.5),
        theme.colorScheme.onErrorContainer,
      ),
      _KpiTone.neutral => (
        theme.colorScheme.surfaceContainerLow,
        theme.colorScheme.onSurface,
      ),
    };
    return Semantics(
      container: true,
      label: '${data.label}，$value',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: UtenRadius.mdAll,
        ),
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Row(
            children: [
              Icon(data.icon, size: 20, color: foreground),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      data.label,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: foreground.withValues(alpha: 0.78),
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompactKpiTile extends StatelessWidget {
  const _CompactKpiTile({required this.data, required this.loading});

  final _KpiData data;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = _displayValue(data, loading);
    return Semantics(
      container: true,
      label: '${data.label}，$value',
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s12,
          vertical: UtenSpacing.s8,
        ),
        child: Row(
          children: [
            Icon(
              data.icon,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    data.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _displayValue(_KpiData data, bool loading) {
  if (loading) return '加载中';
  if (data.value == null) return '—';
  return data.currency ? '¥${data.value}' : data.value!;
}

class _KpiData {
  const _KpiData(
    this.label,
    this.value,
    this.icon, {
    this.currency = true,
    this.tone = _KpiTone.neutral,
  });

  final String label;
  final String? value;
  final IconData icon;
  final bool currency;
  final _KpiTone tone;
}

enum _KpiTone { primary, danger, neutral }
