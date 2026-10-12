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
