import 'package:flutter/material.dart';

import '../../core/l10n/gen/app_localizations.dart';
import '../formatters/exact_decimal.dart';
import '../models/procurement_order_closure.dart';

/// The server owns the remaining quantities. Never infer missing legacy values.
/// Shared by single/batch confirmation and business/finance closure details.
class ProcurementOrderClosureQuantities extends StatelessWidget {
  const ProcurementOrderClosureQuantities({
    super.key,
    required this.line,
    this.cancelled = false,
  });

  final ProcurementOrderClosureLine line;
  final bool cancelled;

  @override
  Widget build(BuildContext context) {
    final words = AppLocalizations.of(context);
    String quantity(String? value) => financeExactTrimmed(value) ?? '—';
    String field(String label, String? value) =>
        '$label: ${quantity(value)} ${line.unitName}';
    bool nonzero(String value) => quantity(value) != '0';
    return Text(
      [
        '${line.goodsCode} ${line.goodsName}',
        '${field(words.orderClosureOrdered, line.orderedQty)} · '
            '${field(words.orderClosureReceived, line.receivedQty)}',
        if (nonzero(line.returnedQty) || nonzero(line.settledLossQty))
          '${field(words.orderClosureReturned, line.returnedQty)} · '
              '${field(words.orderClosureSettledLoss, line.settledLossQty)}',
        '${field(cancelled ? words.orderClosureCancelled : words.orderClosureRemaining, line.remainingQty)} · '
            '${field(cancelled ? words.orderClosureCancelledGift : words.orderClosureRemainingGift, line.remainingGiftQty)}',
        if (nonzero(line.giftQty) ||
            nonzero(line.giftReceivedQty) ||
            nonzero(line.giftReturnedQty))
          '${field(words.orderClosureOrderedGift, line.giftQty)} · '
              '${field(words.orderClosureReceivedGift, line.giftReceivedQty)} · '
              '${field(words.orderClosureReturnedGift, line.giftReturnedQty)}',
      ].join('\n'),
    );
  }
}
