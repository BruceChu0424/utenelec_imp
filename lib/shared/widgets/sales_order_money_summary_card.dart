import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../core/theme/uten_tokens.dart';
import '../../features/finance/models/customer_prepayment.dart';
import '../../features/finance/models/finance_decimal.dart';
import '../../features/finance/repositories/customer_prepayment_repository.dart';
import '../auth/permissions.dart';

class SalesOrderMoneySummaryCard extends ConsumerStatefulWidget {
  const SalesOrderMoneySummaryCard({super.key, required this.salesOrderId});

  final String salesOrderId;

  @override
  ConsumerState<SalesOrderMoneySummaryCard> createState() =>
      _SalesOrderMoneySummaryCardState();
}

class _SalesOrderMoneySummaryCardState
    extends ConsumerState<SalesOrderMoneySummaryCard> {
  SalesOrderMoneySummary? _summary;
  bool _loading = false;
  bool _requested = false;
  String? _error;

  bool _canView(Set<String> permissions) =>
      permissions.contains(Perm.financeViewAll) &&
      permissions.contains(Perm.customerPrepaymentView);

  void _scheduleLoad() {
    if (_requested || _loading) return;
    _requested = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final summary = await ref
          .read(customerPrepaymentRepositoryProvider)
          .salesOrderSummary(widget.salesOrderId);
      if (!mounted) return;
      setState(() => _summary = summary);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '订单资金汇总加载失败');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final permissions = ref.watch(currentPermissionsProvider);
    if (!_canView(permissions)) return const SizedBox.shrink();
    _scheduleLoad();
    final theme = Theme.of(context);
    return Card(
      key: const ValueKey('sales-order-money-summary'),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.account_balance_wallet_outlined,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    '订单资金状态（财务只读）',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '刷新订单资金状态',
                  onPressed: _loading ? null : _load,
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                ),
              ],
            ),
            if (_loading && _summary == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: UtenSpacing.s16),
                child: Center(
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              )
            else if (_error != null && _summary == null)
              _errorBody(theme)
            else if (_summary case final summary?)
              _summaryBody(theme, summary),
          ],
        ),
      ),
    );
  }

  Widget _errorBody(ThemeData theme) => Padding(
    padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _error!,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
        const SizedBox(height: UtenSpacing.s4),
        TextButton.icon(
          onPressed: () {
            _requested = true;
            _load();
          },
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('重试'),
        ),
      ],
    ),
  );

  Widget _summaryBody(ThemeData theme, SalesOrderMoneySummary summary) {
    final currency = summary.currencyCode ?? '订单币种';
    final metrics = <(String, String?, bool)>[
      ('订单总额', summary.orderTotalOriginal, false),
      ('正式应收', summary.formalArOriginal, false),
      ('现金累计已收', summary.cashReceivedOriginal, false),
      ('累计冲销', summary.writeOffOriginal, false),
      ('预收累计到账', summary.prepaymentReceivedOriginal, false),
      ('预收累计已抵', summary.prepaymentAppliedOriginal, false),
      ('可用预收', summary.prepaymentAvailableOriginal, true),
      ('正式应收未收', summary.arOutstandingOriginal, true),
      ('订单计划未收', summary.plannedRemainingOriginal, true),
      ('订单超收', summary.overpaidOriginal, false),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '来源：已审核财务收款单、销售发运形成的正式应收及服务端预收抵销。'
          '不读取历史订单订金快照，也不在客户端自行抵减。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 600;
            final width = compact
                ? constraints.maxWidth
                : (constraints.maxWidth - UtenSpacing.s8) / 2;
            return Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              children: [
                for (final metric in metrics)
                  SizedBox(
                    width: width,
                    child: _metric(
                      theme,
                      metric.$1,
                      metric.$2,
                      currency,
                      emphasis: metric.$3,
                    ),
                  ),
              ],
            );
          },
        ),
        if (summary.hasUnallocated || summary.warnings.isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(UtenSpacing.s8),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(UtenRadius.md),
            ),
            child: Text(
              [
                if (summary.hasUnallocated) '存在未绑定订单的预收明细，请由财务核对',
                ...summary.warnings,
              ].join('\n'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _metric(
    ThemeData theme,
    String label,
    String? value,
    String currency, {
    required bool emphasis,
  }) => Container(
    padding: const EdgeInsets.all(UtenSpacing.s8),
    decoration: BoxDecoration(
      color: emphasis
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.45)
          : theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(UtenRadius.md),
      border: Border.all(color: theme.colorScheme.outlineVariant),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: UtenSpacing.s4),
        Text(
          '$currency ${financeExactMoneyDisplay(value)}',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    ),
  );
}
