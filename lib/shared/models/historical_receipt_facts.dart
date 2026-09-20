import '../formatters/exact_decimal.dart';

const historicalReceiptReadOnlyMessage = '历史收货原始记录仅供核对，不能编辑、删除、再次审核入库或红冲。';

String? receiptRecordedDecimal(Map<String, dynamic> json, String key) {
  final exactKey = '${key}Exact';
  return financeExactDecimal(
    json.containsKey(exactKey) ? json[exactKey] : json[key],
  );
}

String historicalReceiptAmount(String? value) =>
    financeExactDecimal(value) == null ? '未知' : financeExactMoneyDisplay(value);

String historicalReceiptRate(String? value) {
  final exact = financeExactDecimal(value);
  if (exact == null) return '未知';
  final coefficient = BigInt.parse(exact.replaceAll('.', ''));
  return coefficient > BigInt.zero ? exact : '未知（原始值 $exact）';
}

String historicalReceiptTotal(Iterable<String?> values) {
  final rows = values.toList(growable: false);
  final unknown = rows
      .where((value) => financeExactDecimal(value) == null)
      .length;
  if (unknown > 0) return '未知（$unknown 行未记载）';
  return rows.isEmpty
      ? '未知（无明细）'
      : historicalReceiptAmount(financeExactSumTexts(rows));
}

class HistoricalReceiptLineFacts {
  const HistoricalReceiptLineFacts({
    required this.quantity,
    required this.unitId,
    required this.unitName,
    required this.original,
    required this.local,
  });
  final String? quantity;
  final String? unitId;
  final String unitName;
  final String? original;
  final String? local;
}
