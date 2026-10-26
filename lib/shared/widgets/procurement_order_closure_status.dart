import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/data_display/uten_status_badge.dart';
import '../../components/forms/maker_audit_fields.dart' show utenFmtIsoTime;
import '../../core/l10n/gen/app_localizations.dart';
import '../../core/theme/uten_tokens.dart';
import '../models/procurement_order_closure.dart';
import 'procurement_order_closure_quantities.dart';

class ProcurementOrderClosureStatus extends StatelessWidget {
  const ProcurementOrderClosureStatus({
    super.key,
    required this.request,
    required this.orderType,
    this.canOpenReplacement = false,
    this.canEditReplacement = false,
    this.canOpenReview = false,
  });

  final ProcurementOrderClosureRequest request;
  final String orderType;
  final bool canOpenReplacement;
  final bool canEditReplacement;
  final bool canOpenReview;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Card(
      key: const Key('procurement-order-closure-status'),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: UtenStatusBadge(
                label: request.isDirect && request.isApproved
                    ? l10n.orderClosureDirectEnded
                    : request.isPending
                    ? l10n.orderClosurePending
                    : request.isApproved
                    ? l10n.orderClosureApproved
                    : request.isRejected
                    ? l10n.orderClosureRejected
                    : request.isCanceled
                    ? l10n.orderClosureRequestCanceled
                    : l10n.orderClosureReviewTitle,
                type: request.isPending
                    ? UtenStatusBadgeType.warning
                    : request.isRejected
                    ? UtenStatusBadgeType.danger
                    : request.isCanceled
                    ? UtenStatusBadgeType.neutral
                    : UtenStatusBadgeType.success,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            Text(
              request.mode == 'CLOSE_AND_REORDER'
                  ? l10n.orderClosureReorder
                  : l10n.orderClosureAction,
            ),
            Text('${l10n.orderClosureReason}: ${request.reason ?? '—'}'),
            if (request.isApproved) ...[
              Text(
                orderType == 'PURCHASE'
                    ? l10n.orderClosureCancelledByPurchase
                    : l10n.orderClosureCancelledBySubcontract,
              ),
              if (request.closedByName?.isNotEmpty == true)
                Text('${l10n.orderClosureOperator}: ${request.closedByName}'),
              if (request.closedAt?.isNotEmpty == true)
                Text(
                  '${l10n.orderClosureClosedAt}: ${utenFmtIsoTime(request.closedAt)}',
                ),
              if (request.unverifiedQuantity)
                Text(l10n.orderClosureUnverifiedQuantity),
              if (request.items.isNotEmpty)
                Text(l10n.orderClosureQuantityBasisHint),
              for (final line in request.items)
                Padding(
                  padding: const EdgeInsets.only(top: UtenSpacing.s8),
                  child: ProcurementOrderClosureQuantities(
                    line: line,
                    cancelled: true,
                  ),
                ),
            ],
            if (request.rejectionReason?.isNotEmpty == true)
              Text(
                request.rejectionReason!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (request.isPending) Text(l10n.orderClosureLegacyPendingHint),
            Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              children: [
                if (canOpenReview && request.caseId.isNotEmpty)
                  UtenButton(
                    type: UtenButtonType.secondary,
                    onPressed: () => context.push(
                      '/finance/procurement-approvals/${Uri.encodeComponent(request.caseId)}',
                    ),
                    child: Text(
                      request.isDirect
                          ? l10n.orderClosureRecordTitle
                          : l10n.orderClosureReviewTitle,
                    ),
                  ),
                if (canOpenReplacement &&
                    request.replacementOrderId?.isNotEmpty == true)
                  UtenButton(
                    key: const Key('procurement-order-closure-replacement'),
                    type: UtenButtonType.secondary,
                    icon: Icons.open_in_new_rounded,
                    onPressed: () => context.push(
                      '/${orderType == 'PURCHASE' ? 'purchase' : 'subcontract'}/orders/${Uri.encodeComponent(request.replacementOrderId!)}${canEditReplacement ? '/edit' : ''}',
                    ),
                    child: Text(
                      '${l10n.orderClosureReorder} ${request.replacementBillNo ?? ''}',
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
