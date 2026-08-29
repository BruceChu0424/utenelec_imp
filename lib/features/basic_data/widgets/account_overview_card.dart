import 'package:flutter/material.dart';

import '../../../components/cards/uten_card.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/currency_display.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../models/account_node.dart';

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
    final metrics = <Widget>[
      _OverviewTile(
        key: const ValueKey('account-overview-total'),
        icon: Icons.account_balance_outlined,
        label: '账户总数',
        value: totalAccounts.toString(),
        description: filteredType == null ? '全部账户主档' : '顶部总览仍按全部账户；列表已预筛',
      ),
      if (canViewBalance && summary != null)
        _OverviewTile(
          icon: Icons.warning_amber_rounded,
          label: '低余额预警',
          value: summary!.warningAccounts.toString(),
          description: '含负余额 ${summary!.negativeAccounts} 个',
          tone: summary!.warningAccounts > 0 || summary!.negativeAccounts > 0
              ? theme.colorScheme.error
              : UtenColors.success,
        ),
      if (canViewBalance)
        for (final currency
            in summary?.currencies ?? const <AccountCurrencySummary>[])
          if (currency.activeAccountCount > 0)
            _OverviewTile(
              icon: Icons.account_balance_wallet_outlined,
              label: _currencyLabel(currency),
              value: financeExactMoneyDisplay(currency.balanceTotalText),
              description:
                  '仅统计 ${currency.activeAccountCount} 个使用中账户'
                  ' · 预警 ${currency.warningCount}',
            ),
    ];
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: UtenRadius.mdAll,
                ),
                child: Icon(
                  Icons.assessment_outlined,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: UtenSpacing.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '账户概览',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      canViewBalance
                          ? '金额按币种分别展示，不跨币种相加；警戒线只影响预警，不改余额。'
                          : '当前仅展示非敏感账户数量；余额、预警与流水需单独授权。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          Wrap(
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s8,
            children: metrics,
          ),
          if (canViewBalance && loading) ...[
            const SizedBox(height: UtenSpacing.s12),
            const LinearProgressIndicator(),
          ],
          if (canViewBalance && error != null) ...[
            const SizedBox(height: UtenSpacing.s8),
            Semantics(
              liveRegion: true,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      error!,
                      style: TextStyle(color: theme.colorScheme.error),
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
    );
  }

  static String _currencyLabel(AccountCurrencySummary currency) {
    return financeCurrencyDisplayLabel(
          name: currency.currencyName,
          code: currency.currencyCode,
        ) ??
        '未设置币种';
  }
}

class _OverviewTile extends StatelessWidget {
  const _OverviewTile({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.description,
    this.tone,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? description;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = tone ?? theme.colorScheme.primary;
    final semantics = [label, value, ?description].join('，');
    return Semantics(
      container: true,
      label: semantics,
      child: Container(
        constraints: const BoxConstraints(minWidth: 176, minHeight: 78),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: UtenRadius.mdAll,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(width: UtenSpacing.s8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 210),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: color,
                    ),
                  ),
                  if (description != null)
                    Text(
                      description!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
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
