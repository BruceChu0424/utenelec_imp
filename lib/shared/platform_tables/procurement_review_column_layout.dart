/// Finance reads identity, quantity, price and accounting terms in that order.
/// Source references and notes follow the values being approved.
const financeProcurementReviewLayoutVersion = 2;

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
  'amountOriginal',
  'currency',
  'exchangeRate',
  'amountLocal',
  'taxRate',
  'settlement',
  'deliverDate',
  'sourceDocNo',
  'sourceApplicationNos',
  'remark',
];

/// Move the former default placement without disturbing custom or pinned columns.
List<String> migrateFinanceProcurementReviewCurrencyOrder(
  List<String> order,
  Set<String> pinned,
) {
  final currency = order.indexOf('currency');
  if (currency <= 0 ||
      currency + 1 >= order.length ||
      order[currency - 1] != 'price' ||
      order[currency + 1] != 'amountOriginal' ||
      pinned.contains('currency') ||
      pinned.contains('amountOriginal')) {
    return order;
  }
  return [
    ...order.take(currency),
    'amountOriginal',
    'currency',
    ...order.skip(currency + 2),
  ];
}

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
