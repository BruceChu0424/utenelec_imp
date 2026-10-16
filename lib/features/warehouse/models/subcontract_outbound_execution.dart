import 'dart:convert';

import '../../subcontract/models/subcontract_doc.dart';
import '../../../shared/formatters/exact_decimal.dart';

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
          'unitRate': item.unitRateText,
          'qty': item.qtyText,
          'weight': item.weight,
          'qtyFromWeight': item.qtyFromWeight,
          'remark': item.remark,
        },
    ],
  });
}

/// Previous drafts encoded numeric facts as JSON numbers (or pipe-separated
/// fields). Canonical equality preserves safe old drafts; rounded facts differ
/// from current recorded text and require review without deleting the draft.
bool subcontractOutboundSnapshotMatches(Object? saved, Object? current) {
  Object? normalized(Object? value, [String? key]) {
    if (value is String && (value.startsWith('{') || value.startsWith('['))) {
      try {
        return normalized(jsonDecode(value));
      } on FormatException {
        return value;
      }
    }
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return {for (final key in keys) key: normalized(value[key], key)};
    }
    if (value is List) return [for (final item in value) normalized(item)];
    if (const {'qty', 'unitRate', 'requestedQty'}.contains(key)) {
      final decimal = financeExactDecimal(value);
      return decimal == null ? value : financeExactTrimmed(decimal);
    }
    return value;
  }

  // The legacy single-document identity used these eight fixed fields.
  if (saved is String && current is String && current.contains('|')) {
    final before = saved.split('|');
    final after = current.split('|');
    if (before.length != 8 || after.length != 8) return false;
    for (var index = 0; index < 8; index++) {
      final key = index == 4
          ? 'unitRate'
          : index == 7
          ? 'requestedQty'
          : null;
      if (normalized(before[index], key) != normalized(after[index], key)) {
        return false;
      }
    }
    return true;
  }
  return jsonEncode(normalized(saved)) == jsonEncode(normalized(current));
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
