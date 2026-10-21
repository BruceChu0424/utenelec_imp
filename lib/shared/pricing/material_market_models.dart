import 'price_analysis_models.dart';

/// Market quotes and forecasts are separate from ERP transaction observations.
/// Decimal values stay text; no client conversion changes their denomination.
class MaterialMarketBenchmark {
  MaterialMarketBenchmark(Map<String, dynamic> json)
    : data = Map.unmodifiable(json);

  final Map<String, dynamic> data;
  String text(String key) => data[key]?.toString() ?? '';
  String get seriesId => text('seriesId');
  String get name => text('name');
  bool get selectable => data['selectable'] == true;
  String get denomination => [
    text('currency'),
    text('unit'),
  ].where((value) => value.isNotEmpty).join(' / ');
}

class MaterialMarketSnapshot extends MaterialMarketBenchmark {
  MaterialMarketSnapshot(super.json);

  String get status => text('status');
  Map<String, dynamic> get validation => priceMap(data['validation']);
  List<MaterialMarketForecast> get forecasts => priceMaps(
    data['forecasts'],
  ).map(MaterialMarketForecast.new).toList(growable: false);
  bool get validated =>
      data['schemaVersion'] == 1 &&
      status == 'READY' &&
      validation['passed'] == true &&
      text('validationBasis') != 'LATEST_HISTORY_REPLAY';
  bool get researchOnly =>
      data['schemaVersion'] == 2 &&
      status == 'RESEARCH_ONLY' &&
      validation['passed'] == true &&
      text('validationBasis') == 'LATEST_HISTORY_REPLAY' &&
      text('modelPriceBasis') == 'CHAIN_LINKED_CURRENT_ANCHOR';
}

DateTime? _utc(Object? value) {
  final parsed = DateTime.tryParse(value?.toString() ?? '');
  return parsed?.isUtc == true ? parsed : null;
}

class MaterialMarketQuote {
  MaterialMarketQuote(Map<String, dynamic> json)
    : data = Map.unmodifiable(json);
  final Map<String, dynamic> data;
  String text(String key) => data[key]?.toString() ?? '';
  DateTime? get expiresAt => _utc(data['expiresAt']);
  bool currentAt(DateTime now) =>
      text('status') == 'CURRENT' &&
      expiresAt != null &&
      now.toUtc().isBefore(expiresAt!);
  String get denomination => [
    text('currency'),
    text('unit'),
  ].where((value) => value.isNotEmpty).join(' / ');
}

class MaterialMarketForecast {
  MaterialMarketForecast(Map<String, dynamic> json)
    : data = Map.unmodifiable(json);

  final Map<String, dynamic> data;
  String text(String key) => data[key]?.toString() ?? '';
  int? get horizon => int.tryParse(text('horizon'));
}

class MaterialMarketAnalysis {
  MaterialMarketAnalysis(Map<String, dynamic> json)
    : data = Map.unmodifiable(json) {
    if (bindingVersion == null || bindingVersion! < 0 || status.isEmpty) {
      throw const FormatException('Invalid market envelope');
    }
  }

  final Map<String, dynamic> data;
  String get status => data['status']?.toString() ?? '';
  String? get seriesId => data['seriesId'] as String?;
  int? get bindingVersion => int.tryParse('${data['bindingVersion']}');
  bool get canManage => data['canManage'] == true;
  DateTime? get expiresAt => _utc(data['expiresAt']);
  int? get refreshAfterSeconds {
    final value = int.tryParse('${data['refreshAfterSeconds']}');
    return value != null && value >= 15 && value <= 3600 ? value : null;
  }

  MaterialMarketBenchmark? get benchmark {
    final json = priceMap(data['benchmark']);
    return json.isEmpty ? null : MaterialMarketBenchmark(json);
  }

  Map<String, dynamic> get sync => priceMap(data['sync']);
  MaterialMarketQuote? get latestQuote {
    final json = priceMap(data['latestQuote']);
    return json.isEmpty ? null : MaterialMarketQuote(json);
  }

  List<String> get reasonCodes => priceStrings(data['reasonCodes']);
  MaterialMarketSnapshot? get current {
    final json = priceMap(data['current']);
    return json.isEmpty ? null : MaterialMarketSnapshot(json);
  }

  /// A stale or unverified envelope never enables an active market signal.
  bool freshAt(DateTime now) =>
      expiresAt != null && now.toUtc().isBefore(expiresAt!);
  bool actionableAt(DateTime now) =>
      freshAt(now) && status == 'READY' && current?.validated == true;
  bool researchOnlyAt(DateTime now) =>
      freshAt(now) &&
      status == 'RESEARCH_ONLY' &&
      current?.researchOnly == true;
  bool canShowProjectionAt(DateTime now) =>
      freshAt(now) &&
      (status == 'READY' || status == 'BASELINE_ONLY' || researchOnlyAt(now)) &&
      current != null;
  bool get actionable => actionableAt(DateTime.now());
  bool get canShowProjection => canShowProjectionAt(DateTime.now());
}
