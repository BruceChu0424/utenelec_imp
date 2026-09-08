import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../core/l10n/gen/app_localizations.dart';
import '../../core/theme/uten_tokens.dart';
import '../../features/finance/models/customer_prepayment.dart';
import '../formatters/exact_decimal.dart';
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
  bool _expanded = false;
  String? _error;
  int _requestVersion = 0;

  @override
  void didUpdateWidget(covariant SalesOrderMoneySummaryCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.salesOrderId != widget.salesOrderId) {
      ++_requestVersion;
      _summary = null;
      _requested = false;
      _loading = false;
      _error = null;
    }
  }

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
    final requestVersion = ++_requestVersion;
    final orderId = widget.salesOrderId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final summary = await ref
          .read(customerPrepaymentRepositoryProvider)
          .salesOrderSummary(orderId);
      if (!mounted ||
          requestVersion != _requestVersion ||
          orderId != widget.salesOrderId) {
        return;
      }
      setState(() => _summary = summary);
    } on ApiException catch (error) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() => _error = error.message);
    } catch (_) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() => _error = '订单资金汇总加载失败');
    } finally {
      if (mounted && requestVersion == _requestVersion) {
        setState(() => _loading = false);
      }
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
                    '订单资金状态',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (_summary != null)
                  IconButton(
                    tooltip: _expanded ? '收起明细' : '展开明细',
                    key: const ValueKey('sales-order-money-summary-toggle'),
                    onPressed: () => setState(() => _expanded = !_expanded),
                    icon: Icon(
                      _expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 22,
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

  /// 折叠态常显的两笔钱（2026-09-05 用户口径）：订单总额 + 已收金额，
  /// 其余明细默认收起、点右上箭头展开。字段重命名避免三个派生口径
  /// （可用预收=预收到账−已抵、超收与待收互补）叠在一起看花眼。
  Widget _summaryBody(ThemeData theme, SalesOrderMoneySummary summary) {
    final words = Localizations.of<AppLocalizations>(context, AppLocalizations);
    final hasReturns =
        (financeExactDecimalUnits(summary.returnCreditOriginal) ??
            BigInt.zero) >
        BigInt.zero;
    final hasPendingBalance =
        (financeExactDecimalUnits(summary.customerPendingBalanceOriginal) ??
            BigInt.zero) >
        BigInt.zero;
    final detailMetrics = <(String, String?, bool)>[
      (
        words?.moneySummaryCustomerPaid ?? '客户已付',
        summary.cashReceivedOriginal,
        true,
      ),
      ('其中：预收到账', summary.prepaymentReceivedOriginal, false),
      ('预收已抵扣', summary.prepaymentAppliedOriginal, false),
      ('可用预收余额', summary.prepaymentAvailableOriginal, true),
      ('累计冲销', summary.writeOffOriginal, false),
      (
        words?.moneySummaryGrossShipped ?? '已发货金额',
        summary.formalArOriginal,
        false,
      ),
      (
        words?.moneySummaryReturned ?? '退货金额',
        summary.returnCreditOriginal,
        false,
      ),
      (
        words?.moneySummaryUnusedReturns ?? '尚未处理的退货金额',
        summary.unusedReturnCreditOriginal,
        false,
      ),
      (
        words?.moneySummaryNetReceivable ?? '当前还需收款',
        summary.netReceivableOriginal,
        true,
      ),
      (
        words?.moneySummaryFutureShipment ?? '后续发货金额',
        summary.unrecognizedOrderOriginal,
        false,
      ),
      (
        words?.moneySummaryExpectedNewCash ?? '预计还需新收',
        summary.plannedRemainingOriginal,
        true,
      ),
      if (hasPendingBalance)
        (
          words?.moneySummaryPendingBalance ?? '客户待处理余额',
          summary.customerPendingBalanceOriginal,
          true,
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
                SizedBox(
                  width: width,
                  child: _metric(theme, '订单总额', summary.orderTotalOriginal),
                ),
                SizedBox(
                  width: width,
                  child: _metric(
                    theme,
                    words?.moneySummaryCustomerPaid ?? '客户已付',
                    summary.cashReceivedOriginal,
                    emphasis: true,
                  ),
                ),
              ],
            );
          },
        ),
        if (hasReturns || hasPendingBalance) ...[
          const SizedBox(height: UtenSpacing.s8),
          Wrap(
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s8,
            children: [
              _metric(
                theme,
                words?.moneySummaryReturned ?? '退货金额',
                summary.returnCreditOriginal,
              ),
              _metric(
                theme,
                words?.moneySummaryNetReceivable ?? '当前还需收款',
                summary.netReceivableOriginal,
                emphasis: true,
              ),
              if (hasPendingBalance)
                _metric(
                  theme,
                  words?.moneySummaryPendingBalance ?? '客户待处理余额',
                  summary.customerPendingBalanceOriginal,
                  emphasis: true,
                ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s4),
          Text(
            words?.moneySummaryBalanceHint ?? '待处理余额需财务确认抵扣或退款，不表示已退款。',
            style: theme.textTheme.bodySmall,
          ),
        ],
        AnimatedSize(
          key: const ValueKey('sales-order-money-summary-details'),
          duration: const Duration(milliseconds: 180),
          alignment: Alignment.topCenter,
          child: _expanded
              ? Padding(
                  padding: const EdgeInsets.only(top: UtenSpacing.s8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        words?.moneySummarySourceHint ??
                            '金额来自已审核单据。客户已付可能含代扣费用，银行实际到账以账户流水为准。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s8),
                      Text(
                        words?.moneySummaryCollectionHint ??
                            '按当前应收、后续发货及未使用预收估算，不会自动抵扣或退款。',
                        style: theme.textTheme.bodySmall,
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
                              for (final metric in detailMetrics)
                                SizedBox(
                                  width: width,
                                  child: _metric(
                                    theme,
                                    metric.$1,
                                    metric.$2,
                                    emphasis: metric.$3,
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                )
              : const SizedBox(width: double.infinity),
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
                if (summary.hasUnallocated)
                  words?.moneySummaryUnallocatedHint ?? '部分付款尚未对应到订单，请财务核对。',
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
    String? value, {
    bool emphasis = false,
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
          financeExactMoneyDisplay(value),
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    ),
  );
}
