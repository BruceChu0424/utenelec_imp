import '../../shared/formatters/exact_decimal.dart';
import '../models/paged_result.dart';

/// Financial values stay decimal text. Only chart coordinates use doubles.
class PriceObservation {
  PriceObservation(this.data);
  final Map<String, dynamic> data;
  String text(String key) => data[key]?.toString() ?? '';
  String get price => text('unitPrice');
  DateTime? get date => DateTime.tryParse(text('businessDate'));
  bool get comparable => data['comparable'] == true;
  String get identity => [
    'sourceType',
    'sourceId',
    'sourceItemId',
    'historyVersionId',
  ].map(text).join('|');
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

class PriceHistoryTableResult extends PagedResult<PriceObservation> {
  PriceHistoryTableResult.fromResponse(Map<String, dynamic> raw)
    : this._(
        PagedResult.fromJson({
          ...raw,
          'items': raw['observations'],
          'facetNullCounts': raw['nullCounts'],
        }, PriceObservation.new),
        raw,
      );
  PriceHistoryTableResult._(PagedResult<PriceObservation> page, this.metadata)
    : super(
        items: page.items,
        page: page.page,
        size: page.size,
        total: page.total,
        totalPages: page.totalPages,
        facets: page.facets,
        facetNullCounts: page.facetNullCounts,
      );
  final Map<String, dynamic> metadata;
  bool hasMoreFacetValues(String key) =>
      priceMap(metadata['facetsHasMore'])[key] == true;
}

class PriceObservationDetail {
  PriceObservationDetail(this.data);
  final Map<String, dynamic> data;
  PriceObservation get observation =>
      PriceObservation(priceMap(data['observation']));
  String get title => data['title']?.toString() ?? '';
  String get summary => data['summary']?.toString() ?? '';
  List<Map<String, dynamic>> get fields => priceMaps(data['fields']);
  List<String> get reasons => priceStrings(data['reasonCodes']);
}

/// Display projection only; row/exactValueOf continue to expose the raw decimal.
String priceObservationValue(PriceObservation row, String key) {
  final amount = priceNumber(row.data[key]);
  final currency = row.text('currencyName'), unit = row.text('unitName');
  final suffix = switch (key) {
    'quantity' => unit,
    'amount' => currency,
    'unitPrice' => [currency, unit].where((v) => v.isNotEmpty).join('/'),
    _ => '',
  };
  return suffix.isEmpty ? amount : '$amount $suffix';
}
