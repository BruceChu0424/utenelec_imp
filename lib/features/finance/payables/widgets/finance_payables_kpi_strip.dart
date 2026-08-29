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
    final items = <_KpiData>[
      _KpiData('应付(本币)', summary?.payableLocal, Icons.receipt_long_outlined),
      _KpiData('现金已付(本币)', summary?.paidLocal, Icons.task_alt_rounded),
      _KpiData('账面核销(本币)', summary?.settledBookLocal, Icons.menu_book_outlined),
      _KpiData(
        '汇兑差额(本币)',
        summary?.exchangeDifferenceLocal,
        Icons.currency_exchange_outlined,
      ),
      _KpiData('抵销(本币)', summary?.offsetLocal, Icons.rule_rounded),
      _KpiData(
        '未付(本币)',
        summary?.outstandingLocal,
        Icons.account_balance_wallet_outlined,
      ),
      _KpiData(
        '本月到期',
        summary?.dueThisMonthLocal,
        Icons.event_available_outlined,
      ),
      _KpiData('逾期(本币)', summary?.overdueLocal, Icons.warning_amber_rounded),
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
        const gap = UtenSpacing.s8;
        final compact = constraints.maxWidth < 600;
        final columns = constraints.maxWidth >= 1200 ? 5 : 3;
        final width = compact
            ? 190.0
            : (constraints.maxWidth - (columns - 1) * gap) / columns;
        final tiles = [
          for (final item in items)
            SizedBox(
              width: width,
              child: _KpiTile(data: item, loading: loading),
            ),
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (compact)
              SingleChildScrollView(
                key: const ValueKey('finance-payables-kpi-scroll'),
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var index = 0; index < tiles.length; index++) ...[
                      tiles[index],
                      if (index != tiles.length - 1) const SizedBox(width: gap),
                    ],
                  ],
                ),
              )
            else
              Wrap(spacing: gap, runSpacing: gap, children: tiles),
            const SizedBox(height: UtenSpacing.s8),
            Semantics(
              label: '应付减账面核销减抵销等于未付，现金已付与汇兑差额分列',
              child: Text(
                '核对恒等式：应付 − 账面核销 − 抵销 = 未付；'
                '现金已付与汇兑差额分列，不直接拿现金冲平账面。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _KpiTile extends StatelessWidget {
  const _KpiTile({required this.data, required this.loading});

  final _KpiData data;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = loading
        ? '加载中'
        : (data.value == null
              ? '—'
              : data.currency
              ? '¥${data.value}'
              : data.value!);
    return Semantics(
      container: true,
      label: '${data.label}，$value',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(UtenRadius.md),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Row(
            children: [
              Icon(data.icon, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      data.label,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
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

class _KpiData {
  const _KpiData(this.label, this.value, this.icon, {this.currency = true});

  final String label;
  final String? value;
  final IconData icon;
  final bool currency;
}
