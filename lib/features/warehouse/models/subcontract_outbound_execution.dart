import 'dart:convert';

import '../../subcontract/models/subcontract_doc.dart';

/// Material-issue endpoints currently expose no client version token. This
/// snapshot catches changes observed before saving or approving; the service
/// remains responsible for transaction locks and quantity/status enforcement.
String subcontractOutboundDraftFingerprint(SubcontractDocDetail document) {
  final items = document.items.toList()
    ..sort(
      (a, b) =>
          (a.planItemId ?? a.id ?? '').compareTo(b.planItemId ?? b.id ?? ''),
    );
  return jsonEncode({
    'id': document.id,
    'status': document.status,
    'billDate': document.billDate,
    'supplierId': document.supplierId,
    'warehouseId': document.warehouseId,
    'workerId': document.workerId,
    'deliverDate': document.deliverDate,
    'remark': document.remark,
    'items': [
      for (final item in items)
        {
          'id': item.id,
          'planItemId': item.planItemId,
          'orderItemId': item.orderItemId,
          'goodsId': item.goodsId,
          'colorId': item.colorId,
          'unitId': item.unitId,
          'unitRate': item.unitRate,
          'qty': item.qty,
          'weight': item.weight,
          'remark': item.remark,
        },
    ],
  });
}

enum SubcontractOutboundExecutionState {
  pending,
  saving,
  approving,
  completed,
  needsVerification,
  blocked,
}

/// A request with an uncertain receipt is never put back into the send queue.
/// Only tasks that have not started are eligible for the next explicit batch.
bool subcontractOutboundMaySubmit(SubcontractOutboundExecutionState state) =>
    state == SubcontractOutboundExecutionState.pending;
