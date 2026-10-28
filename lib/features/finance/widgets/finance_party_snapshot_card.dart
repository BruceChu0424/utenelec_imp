// 往来单位财务快照卡(ADR-128)：销售订单财务审核、出货财审、采购/委外订货审批三处共用。
//
// 卡片只显示服务端算好的 [PartyOpenBalance]，不重算：
//  - 单据币种一档：应收未收(应付未付) / 可用预收(可抵预付与贷项) / 还差多少，都写成「币种 金额」；
//  - 其它币种与原币未核实的历史余额在网格下方一行补充，不换算、不相加；
//  - 有额度时([limitLabel] 非空)再列全部币种应收的账面本币毛额、额度与超出额度，超额标红，
//    需要时出横幅([overLimitWarning])；
//  - 页面自己的字段(结账方式、本单金额、汇率等)经 [leading] / [trailing] 插入，
//    页面独有的区块(如出货记账汇率区)经 [footer] 放在卡片底部。
import 'package:flutter/material.dart';

import '../../../components/layout/uten_form_grid.dart';
import '../../../components/layout/uten_collapsible_content.dart';
import '../../../components/data_display/uten_detail_summary_card.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../../../shared/formatters/money_display.dart';
import '../../../shared/models/party_open_balance.dart';

/// 快照卡里的一格：标题 + 数值。
class FinanceSnapshotMetric {
  const FinanceSnapshotMetric(
    this.label,
    this.value, {
    this.emphasis = false,
    this.danger = false,
  });

  final String label;
  final String? value;
  final bool emphasis;
  final bool danger;
}

class FinancePartySnapshotCard extends StatelessWidget {
  const FinancePartySnapshotCard({
    super.key,
    required this.title,
    required this.balance,
    this.titleStyle,
    this.side = PartyBalanceSide.customer,
    this.leading = const [],
    this.trailing = const [],
    this.limitLabel,
    this.overLimitWarning,
    this.footer = const [],
    this.note,
    this.embedded = false,
    this.expanded = true,
    this.showTitle = true,
    this.showLeading = true,
    this.showBalances = true,
  });

  /// 卡片标题，例如「客户财务快照 · 远硕智能(C001)」。
  final String title;

  /// 标题样式覆盖（2026-10-10 订货审批口径：供应商名红色加粗）：null 保持
  /// 默认 titleSmall·w600；非空时经 merge 覆盖默认（基线字号仍随主题）。
  final TextStyle? titleStyle;

  /// 服务端共用余额视图；null = 服务端没给，余额各格显示「—」。
  final PartyOpenBalance? balance;
  final PartyBalanceSide side;

  /// 余额各格之前 / 之后由页面插入的格子。
  final List<FinanceSnapshotMetric> leading;
  final List<FinanceSnapshotMetric> trailing;

  /// 和余额比较的额度叫什么(「信用额度」「铺底额」)；null = 本页不比额度。
  final String? limitLabel;

  /// 超额时的横幅文字；null = 只把数字标红，不出横幅。只在给了 [limitLabel] 时生效。
  final String? overLimitWarning;

  /// 卡片底部的页面专属区块。
  final List<Widget> footer;

  /// 最底部的一行灰字说明。
  final String? note;
  final bool embedded;
  final bool expanded;
  final bool showTitle;
  final bool showLeading;
  final bool showBalances;

  bool get _customer => side == PartyBalanceSide.customer;

  List<FinanceSnapshotMetric> _balanceMetrics() {
    final b = balance;
    final over = b?.overCredit == true;
    return [
      FinanceSnapshotMetric(_customer ? '应收未收' : '应付未付', b?.openText),
      FinanceSnapshotMetric(_customer ? '可用预收' : '可抵预付/贷项', b?.creditText),
      FinanceSnapshotMetric('还差多少', b?.headline(side), emphasis: true),
      if (limitLabel case final limit?) ...[
        FinanceSnapshotMetric(
          _customer ? '全部币种应收(折本币)' : '全部币种应付(折本币)',
          b?.baseMoneyText(b.openBookLocal),
          danger: over,
        ),
        FinanceSnapshotMetric(
          limit,
          b == null
              ? null
              : b.creditLimitLocal == null
              ? '未设置'
              : b.baseMoneyText(b.creditLimitLocal),
        ),
        if (b?.creditLimitLocal != null)
          FinanceSnapshotMetric(
            '超出$limit',
            b!.baseMoneyText(b.overLimitLocal),
            danger: over,
          ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (embedded) return _CompactFinanceSnapshot(card: this);
    final theme = Theme.of(context);
    final footnote = balance?.footnote(side);
    // 横幅只在本页比额度([limitLabel])并且服务端判定超额时出现。
    final warning = limitLabel == null ? null : overLimitWarning;
    return Card(
      key: const ValueKey('finance-party-snapshot'),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.account_balance_wallet_outlined,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600)
                        .merge(titleStyle),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s8),
            UtenFormGrid(
              children: [
                for (final metric in [
                  ...leading,
                  ..._balanceMetrics(),
                  ...trailing,
                ])
                  _MetricCell(metric: metric),
              ],
            ),
            if (footnote != null) ...[
              const SizedBox(height: UtenSpacing.s8),
              Text(
                footnote,
                key: const ValueKey('finance-party-snapshot-footnote'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (warning != null && balance?.overCredit == true) ...[
              const SizedBox(height: UtenSpacing.s8),
              Container(
                key: const ValueKey('finance-party-snapshot-over-limit'),
                padding: const EdgeInsets.all(UtenSpacing.s8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(UtenRadius.md),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 18,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Expanded(
                      child: Text(
                        warning,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            ...footer,
            if (note case final text?) ...[
              const SizedBox(height: UtenSpacing.s8),
              Text(
                text,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CompactFinanceSnapshot extends StatelessWidget {
  const _CompactFinanceSnapshot({required this.card});
  final FinancePartySnapshotCard card;

  String money(String? amount, {bool base = false}) =>
      financeMoneyWithUnitSuffix(
        amount,
        currencyName: base
            ? card.balance?.baseCurrencyName
            : card.balance?.currencyName,
        fullCurrencyName: true,
      );

  Widget metric(FinanceSnapshotMetric value) => UtenSummaryField(
    label: value.label,
    value: value.value,
    emphasis: value.emphasis,
    danger: value.danger,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = card.balance;
    final customer = card.side == PartyBalanceSide.customer;
    final net = financeExactDecimal(b?.netOriginal);
    final surplus = (financeAmountUnits(net)?.sign ?? 0) < 0;
    final warning = card.limitLabel != null && b?.overCredit == true;
    return Column(
      key: const ValueKey('finance-party-snapshot'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (card.showLeading && card.leading.isNotEmpty) ...[
          UtenSummaryFacts(
            minFieldWidth: 160,
            children: card.leading.map(metric).toList(),
          ),
          const SizedBox(height: UtenSpacing.s12),
        ],
        if (card.showTitle)
          Text(
            card.title,
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w600)
                .merge(card.titleStyle),
          ),
        if (card.showTitle && card.showBalances)
          const SizedBox(height: UtenSpacing.s4),
        if (card.showBalances)
          UtenSummaryFacts(
            inline: false,
            minFieldWidth: 180,
            maxColumns: 3,
            children: [
              UtenSummaryField(
                label: customer ? '应收未收' : '应付未付',
                value: money(b?.openOriginal),
              ),
              UtenSummaryField(
                label: customer ? '可用预收' : '可抵预付/贷项',
                value: money(b?.creditOriginal),
              ),
              UtenSummaryField(
                label: surplus ? (customer ? '预收有余' : '可抵有余') : '还差多少',
                value: money(surplus ? net!.substring(1) : net),
                emphasis: true,
              ),
            ],
          ),
        if (b?.footnote(card.side) case final footnote?) ...[
          const SizedBox(height: UtenSpacing.s8),
          Text(
            footnote,
            key: const ValueKey('finance-party-snapshot-footnote'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (warning) ...[
          const SizedBox(height: UtenSpacing.s8),
          Container(
            key: const ValueKey('finance-party-snapshot-over-limit'),
            padding: const EdgeInsets.all(UtenSpacing.s8),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer,
              borderRadius: UtenRadius.mdAll,
            ),
            child: Text(
              '已超${card.limitLabel} ${money(b?.overLimitLocal, base: true)} · '
              '全部币种${customer ? '应收' : '应付'}(折本币、不扣预收) '
              '${money(b?.openBookLocal, base: true)} · '
              '${card.limitLabel} ${money(b?.creditLimitLocal, base: true)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
        if (card.limitLabel != null || card.trailing.isNotEmpty)
          UtenCollapsibleContent(
            expanded: card.expanded,
            maintainState: false,
            child: Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s12),
              child: UtenSummaryFacts(
                inline: true,
                children: [
                  if (card.limitLabel != null) ...[
                    UtenSummaryField(
                      label: '全部币种${customer ? '应收' : '应付'}(折本币)',
                      value: money(b?.openBookLocal, base: true),
                      danger: b?.overCredit == true,
                    ),
                    UtenSummaryField(
                      label: card.limitLabel!,
                      value: b == null
                          ? null
                          : b.creditLimitLocal == null
                          ? '未设置'
                          : money(b.creditLimitLocal, base: true),
                    ),
                    if (b?.creditLimitLocal != null)
                      UtenSummaryField(
                        label: '超出${card.limitLabel}',
                        value: money(b?.overLimitLocal, base: true),
                        danger: b?.overCredit == true,
                      ),
                  ],
                  ...card.trailing.map(metric),
                ],
              ),
            ),
          ),
        ...card.footer,
        if (card.note case final note?) ...[
          const SizedBox(height: UtenSpacing.s8),
          Text(note, style: theme.textTheme.bodySmall),
        ],
      ],
    );
  }
}

class _MetricCell extends StatelessWidget {
  const _MetricCell({required this.metric});

  final FinanceSnapshotMetric metric;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = metric.value?.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          metric.label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value == null || value.isEmpty ? '—' : value,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: metric.emphasis ? FontWeight.w800 : FontWeight.w600,
            color: metric.danger ? theme.colorScheme.error : null,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
