import '../../shared/formatters/exact_decimal.dart';

/// Financial values stay decimal text. Only chart coordinates use doubles.
class PriceObservation {
  PriceObservation(this.data);
  final Map<String, dynamic> data;
  String text(String key) => data[key]?.toString() ?? '';
  String get price => text('unitPrice');
  DateTime? get date => DateTime.tryParse(text('businessDate'));
  bool get comparable => data['comparable'] == true;
}

class GoodsPriceAnalysis {
  GoodsPriceAnalysis(this.data);
  final Map<String, dynamic> data;
  String text(String key) => data[key]?.toString() ?? '';
  Map<String, dynamic> get context => priceMap(data['context']);
  Map<String, dynamic> get cost => priceMap(data['costSummary']);
  List<PriceObservation> get observations => priceMaps(
    data['observations'],
  ).map(PriceObservation.new).toList(growable: false);
  List<String> get reasons => priceStrings(data['reasonCodes']);
  bool get ready => text('status') == 'READY';
  String get denomination => [
    context['currencyName']?.toString() ?? '',
    context['unitName']?.toString() ?? '',
  ].where((s) => s.isNotEmpty).join(' / ');
}

class PriceCheckResult {
  const PriceCheckResult(this.data);
  final Map<String, dynamic> data;
  String text(String key) => data[key]?.toString() ?? '';
  bool get warning => text('severity') == 'WARNING';
  bool get available => text('status') == 'READY';
  static const unavailable = PriceCheckResult({
    'status': 'UNAVAILABLE',
    'severity': 'INSUFFICIENT',
  });
}

Map<String, dynamic> priceMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : const {};
List<Map<String, dynamic>> priceMaps(Object? value) => value is List
    ? value
          .whereType<Map<dynamic, dynamic>>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList()
    : const [];
List<String> priceStrings(Object? value) => value is List
    ? value.whereType<String>().toList(growable: false)
    : const [];

String priceNumber(Object? value) {
  final raw = value?.toString();
  return raw == null || raw.isEmpty ? '—' : financeExactTrimmed(raw) ?? '—';
}

class PriceHistoryPage {
  PriceHistoryPage(this.data);
  final Map<String, dynamic> data;
  List<PriceObservation> get observations => priceMaps(
    data['observations'],
  ).map(PriceObservation.new).toList(growable: false);
  String? get nextCursor => data['nextCursor'] as String?;
  bool get hasMore => data['hasMore'] == true;
}
