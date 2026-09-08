import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../providers/sales_order_finance_confirmation_count_provider.dart';

/// 销售订货单待财务确认徽标（V294 闸门）。
class SalesOrderFinanceConfirmationBadge extends ConsumerWidget {
  const SalesOrderFinanceConfirmationBadge({
    super.key,
    this.size = 20,
    this.showLabel = true,
    this.changesOnly,
  });

  final double size;
  final bool showLabel;
  final bool? changesOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final queue = switch (changesOnly) {
      true => l10n.financeSalesChangesQueueLabel,
      false => l10n.financeSalesInitialQueueLabel,
      null => l10n.financeSalesAllQueueLabel,
    };
    final count = ref.watch(
      changesOnly == null
          ? salesOrderFinanceConfirmationCountProvider
          : salesOrderFinanceQueueCountProvider(changesOnly!),
    );
    return count.when(
      // A refresh can retain an old zero; it must still be described as loading.
      skipLoadingOnRefresh: false,
      skipLoadingOnReload: false,
      data: (value) => Semantics(
        label: value > 0
            ? l10n.financeSalesQueueCountPending(queue, value)
            : l10n.financeSalesQueueCountEmpty(queue),
        excludeSemantics: true,
        child: UtenNotificationBadge(
          count: value,
          size: size,
          showLabel: showLabel,
        ),
      ),
      loading: () => _status(
        l10n.financeSalesQueueCountLoading(queue),
        SizedBox.square(
          dimension: size,
          child: const CircularProgressIndicator(
            key: ValueKey('sales-order-finance-badge-loading'),
            strokeWidth: 2,
          ),
        ),
      ),
      error: (_, _) => _status(
        l10n.financeSalesQueueCountFailed(queue),
        Icon(
          Icons.sync_problem_outlined,
          key: const ValueKey('sales-order-finance-badge-error'),
          size: size,
          color: Theme.of(context).colorScheme.error,
        ),
      ),
    );
  }

  Widget _status(String message, Widget child) => Tooltip(
    message: message,
    excludeFromSemantics: true,
    child: Semantics(
      label: message,
      liveRegion: true,
      excludeSemantics: true,
      child: child,
    ),
  );
}
