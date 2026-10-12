/// The same business columns retain their order when an order moves from
/// creation to review and detail. Workflow progress and accounting projections
/// follow the submitted business fields; additional columns retain their order.
const procurementOrderColumnKeys = <String>[
  'goods',
  'goodsCode',
  'colorName',
  'source',
  'supplier',
  'qty',
  'allowedOverReceiptPct',
  'allowedLossPct',
  'price',
  'amount',
  'currency',
  'taxRate',
  'settlement',
  'remark',
];

const purchaseOrderColumnLayoutVersion = 1;
const purchaseOrderItemsTableKey =
    'purchase.order.items.v2'; // gitleaks:allow public UI layout identifier.

/// Upgrade either legacy purchase-layout source without discarding the user's
/// other columns. Matching pin membership keeps the pair together when the
/// editable grid moves pinned columns to its left prefix.
({List<String> order, Set<String> pinned}) migratePurchaseOrderColumnLayout({
  required List<String> order,
  required Set<String> pinned,
}) {
  final migratedOrder = order.isEmpty
      ? <String>[]
      : (order.toSet().toList()..remove('allowedOverReceiptPct'));
  if (order.isNotEmpty) {
    if (!migratedOrder.contains('qty')) migratedOrder.add('qty');
    migratedOrder.insert(
      migratedOrder.indexOf('qty') + 1,
      'allowedOverReceiptPct',
    );
  }
  final migratedPinned = Set<String>.of(pinned);
  if (migratedPinned.contains('qty')) {
    migratedPinned.add('allowedOverReceiptPct');
  } else {
    migratedPinned.remove('allowedOverReceiptPct');
  }
  return (
    order: List.unmodifiable(migratedOrder),
    pinned: Set.unmodifiable(migratedPinned),
  );
}

String procurementColumnKey(String key) => switch (key) {
  'sourceRequests' ||
  'sourceApplications' ||
  'sourceApplicationNos' => 'source',
  'amountOriginal' => 'amount',
  'settlementMethod' => 'settlement',
  _ => key,
};

List<T> canonicalProcurementColumns<T>(
  List<T> columns, {
  required String Function(T) keyOf,
  bool enabled = true,
}) {
  if (!enabled) return columns;
  final indexed = columns.indexed.toList();
  int rank(T column) {
    final index = procurementOrderColumnKeys.indexOf(
      procurementColumnKey(keyOf(column)),
    );
    return index < 0 ? procurementOrderColumnKeys.length : index;
  }

  indexed.sort((a, b) {
    final comparison = rank(a.$2).compareTo(rank(b.$2));
    return comparison == 0 ? a.$1.compareTo(b.$1) : comparison;
  });
  return [for (final entry in indexed) entry.$2];
}
