import 'package:flutter/material.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/currency_display.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../models/account_node.dart';

/// A single summary band. Each currency has its own balance lane.
class AccountOverviewCard extends StatelessWidget {
  const AccountOverviewCard({
    super.key,
    required this.totalAccounts,
    required this.canViewBalance,
    required this.summary,
    required this.loading,
    required this.error,
    required this.onRetry,
    this.filteredType,
  });

  final int totalAccounts;
  final bool canViewBalance;
  final AccountSummary? summary;
  final bool loading;
  final String? error;
  final VoidCallback onRetry;
  final String? filteredType;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final currencies = canViewBalance
        ? summary?.currencies
                  .where((item) => item.activeAccountCount > 0)
                  .toList() ??
              const <AccountCurrencySummary>[]
        : const <AccountCurrencySummary>[];
    return SizedBox(
      width: double.infinity,
      child: UtenCard(
        padding: const EdgeInsets.all(UtenSpacing.s20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            UtenSectionHeader(
              title: '账户概览',
              icon: Icons.account_balance_outlined,
              info: canViewBalance
                  ? '金额按币种分别展示，不跨币种相加；警戒线只影响预警，不改余额。'
                  : '余额、预警与流水需单独授权。',
            ),
            const SizedBox(height: UtenSpacing.s20),
            LayoutBuilder(
              builder: (context, constraints) {
                final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
                final wide = constraints.maxWidth >= 840 * scale;
                final counts = Wrap(
                  spacing: UtenSpacing.s24,
                  runSpacing: UtenSpacing.s16,
                  children: [
                    _AccountCount(
                      key: const ValueKey('account-overview-total'),
                      label: '账户总数',
                      value: totalAccounts.toString(),
                    ),
                    if (canViewBalance && summary != null)
                      _AccountCount(
                        label: '低余额预警',
                        value: summary!.warningAccounts.toString(),
                        warning:
                            summary!.warningAccounts > 0 ||
                            summary!.negativeAccounts > 0,
                        description: summary!.negativeAccounts > 0
                            ? '负余额 ${summary!.negativeAccounts} 个'
                            : null,
                      ),
                  ],
                );
                final balances = LayoutBuilder(
                  builder: (context, laneConstraints) {
                    final columns = (laneConstraints.maxWidth / (280 * scale))
                        .floor()
                        .clamp(1, currencies.length.clamp(1, 4));
                    final width =
                        (laneConstraints.maxWidth -
                            UtenSpacing.s24 * (columns - 1)) /
                        columns;
                    return Wrap(
                      spacing: UtenSpacing.s24,
                      runSpacing: UtenSpacing.s20,
                      children: [
                        for (final currency in currencies)
                          SizedBox(
                            width: width,
                            child: _CurrencyBalance(currency: currency),
                          ),
                      ],
                    );
                  },
                );
                if (currencies.isEmpty) return counts;
                if (!wide) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      counts,
                      const Padding(
                        padding: EdgeInsets.symmetric(
                          vertical: UtenSpacing.s16,
                        ),
                        child: Divider(height: 1),
                      ),
                      balances,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 240 * scale, child: counts),
                    const SizedBox(width: UtenSpacing.s24),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.only(left: UtenSpacing.s24),
                        decoration: BoxDecoration(
                          border: Border(
                            left: BorderSide(color: colors.outlineVariant),
                          ),
                        ),
                        child: balances,
                      ),
                    ),
                  ],
                );
              },
            ),
            if (canViewBalance && loading) ...[
              const SizedBox(height: UtenSpacing.s16),
              const LinearProgressIndicator(),
            ],
            if (canViewBalance && error != null) ...[
              const SizedBox(height: UtenSpacing.s12),
              Semantics(
                liveRegion: true,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        error!,
                        style: TextStyle(color: colors.error),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('重试'),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AccountCount extends StatelessWidget {
  const _AccountCount({
    super.key,
    required this.label,
    required this.value,
    this.warning = false,
    this.description,
  });

  final String label;
  final String value;
  final bool warning;
  final String? description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = warning
        ? theme.colorScheme.error
        : theme.colorScheme.onSurface;
    return Semantics(
      container: true,
      label: [label, value, ?description].join('，'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            value,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          if (description != null)
            Text(
              description!,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
        ],
      ),
    );
  }
}

class _CurrencyBalance extends StatelessWidget {
  const _CurrencyBalance({required this.currency});

  final AccountCurrencySummary currency;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label =
        financeCurrencyDisplayLabel(
          name: currency.currencyName,
          code: currency.currencyCode,
        ) ??
        '未设置币种';
    final value = financeExactMoneyDisplay(
      currency.balanceTotalText,
      groupThousands: true,
    );
    final description =
        '使用中 ${currency.activeAccountCount}'
        '${currency.warningCount > 0 ? "，预警 ${currency.warningCount}" : ""}';
    return Semantics(
      container: true,
      label: '$label，$value，$description',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            value,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: UtenSpacing.s4),
          Text(
            description,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
