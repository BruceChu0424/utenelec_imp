import 'price_analysis_models.dart';

/// Market quotes and forecasts are separate from ERP transaction observations.
/// Decimal values stay text; no client conversion changes their denomination.
class MaterialMarketSnapshot {
  MaterialMarketSnapshot(Map<String, dynamic> json)
    : data = Map.unmodifiable(json);

  final Map<String, dynamic> data;
  String text(String key) => data[key]?.toString() ?? '';
  String get seriesId => text('seriesId');
  String get name => text('name');
  String get status => text('status');
  Map<String, dynamic> get validation => priceMap(data['validation']);
  List<MaterialMarketForecast> get forecasts => priceMaps(
    data['forecasts'],
  ).map(MaterialMarketForecast.new).toList(growable: false);
  bool get validated => status == 'READY' && validation['passed'] == true;
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
  DateTime? get expiresAt {
    final parsed = DateTime.tryParse(data['expiresAt']?.toString() ?? '');
    return parsed?.isUtc == true ? parsed : null;
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
  bool canShowProjectionAt(DateTime now) =>
      freshAt(now) &&
      (status == 'READY' || status == 'BASELINE_ONLY') &&
      current != null;
  bool get actionable => actionableAt(DateTime.now());
  bool get canShowProjection => canShowProjectionAt(DateTime.now());
}
