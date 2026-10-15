/// Finance reads identity, quantity, price and accounting terms in that order.
/// Source references and notes follow the values being approved.
const financeProcurementReviewColumnKeys = <String>[
  'lineNo',
  'goods',
  'goodsCode',
  'colorName',
  'supplier',
  'qty',
  'allowedOverReceiptPct',
  'allowedLossPct',
  'giftQty',
  'price',
  'currency',
  'amountOriginal',
  'exchangeRate',
  'amountLocal',
  'taxRate',
  'settlement',
  'deliverDate',
  'sourceDocNo',
  'sourceApplicationNos',
  'remark',
];

List<T> financeProcurementReviewColumns<T>(
  List<T> columns, {
  required String Function(T) keyOf,
}) {
  int rank(T column) {
    final index = financeProcurementReviewColumnKeys.indexOf(keyOf(column));
    return index < 0 ? financeProcurementReviewColumnKeys.length : index;
  }

  final indexed = columns.indexed.toList()
    ..sort((a, b) {
      final comparison = rank(a.$2).compareTo(rank(b.$2));
      return comparison == 0 ? a.$1.compareTo(b.$1) : comparison;
    });
  return [for (final entry in indexed) entry.$2];
}
