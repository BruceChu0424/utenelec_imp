import '../formatters/quantity_display.dart';

const warehouseProcurementProgressColumns = <(String, String)>[
  ('stockedQty', '已入库'),
  ('pendingStockInQty', '合格待入库'),
  ('pendingReturnQty', '剩余待退回'),
];

/// Server-owned progress, in the original receipt line's unit and excluding gifts.
class ProcurementReceiptProgress {
  const ProcurementReceiptProgress(this.values);
  final Map<String, dynamic> values;

  String? quantity(String key) => values[key]?.toString();

  String label(String key, String? unitName) {
    final value = formatExactQtyWithUnit(quantity(key), unitName);
    return value.isEmpty ? '—' : value;
  }

  String summary(String? unitName) => [
    for (final (key, title) in warehouseProcurementProgressColumns)
      if (quantity(key) != null) '$title ${label(key, unitName)}',
  ].join('；');
}
