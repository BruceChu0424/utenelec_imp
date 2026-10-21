import '../../../shared/pricing/material_market_models.dart';
import '../../../shared/pricing/price_analysis_models.dart';

class MaterialForecastRuntimeStatus {
  MaterialForecastRuntimeStatus(Map<String, dynamic> json)
    : data = Map.unmodifiable(json) {
    final policy = configuration;
    if (data['configuration'] is! Map ||
        data['runtime'] is! Map ||
        policy['enabled'] is! bool ||
        policy['intervalMinutes'] is! int ||
        policy['historyDays'] is! int ||
        policy['backfillBudget'] is! int ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(revision) ||
        runtime['available'] is! bool ||
        runtime['processRunning'] is! bool ||
        runtime['configurationApplied'] is! bool ||
        runtime['state'] is! String ||
        data['feeds'] is! List ||
        feeds.length > 3) {
      throw const FormatException('Invalid material runtime status');
    }
  }

  final Map<String, dynamic> data;
  Map<String, dynamic> get configuration => priceMap(data['configuration']);
  Map<String, dynamic> get runtime => priceMap(data['runtime']);
  List<Map<String, dynamic>> get feeds => priceMaps(data['feeds']);
  String get revision => configuration['revision']?.toString() ?? '';
  bool get enabled => configuration['enabled'] == true;
  String get state => runtime['state']?.toString() ?? 'UNAVAILABLE';
  DateTime? get expiresAt => _utc(data['expiresAt']);
  int get refreshAfterSeconds {
    final seconds = int.tryParse('${data['refreshAfterSeconds']}');
    return seconds != null && seconds >= 10 && seconds <= 300 ? seconds : 15;
  }

  bool freshAt(DateTime now) =>
      expiresAt != null && now.toUtc().isBefore(expiresAt!);
  bool matchesSaved(Map<String, String> settings) {
    for (final field in const {
      'material_forecast.enabled': 'enabled',
      'material_forecast.interval_minutes': 'intervalMinutes',
      'material_forecast.history_days': 'historyDays',
      'material_forecast.backfill_budget': 'backfillBudget',
    }.entries) {
      final expected = settings[field.key];
      if (expected == null) continue;
      final actual = configuration[field.value];
      if (field.value == 'enabled') {
        if (expected.trim().toLowerCase() != actual.toString()) return false;
      } else if (int.tryParse(expected.trim()) != actual) {
        return false;
      }
    }
    return true;
  }

  bool acknowledgedAt(DateTime now, Map<String, String> saved) =>
      freshAt(now) &&
      matchesSaved(saved) &&
      runtime['configurationApplied'] == true &&
      runtime['desiredRevision'] == revision &&
      runtime['appliedRevision'] == revision &&
      (enabled
          ? state == 'RUNNING' &&
                runtime['available'] == true &&
                runtime['processRunning'] == true
          : state == 'DISABLED' && runtime['processRunning'] == false);

  DateTime? firstDeadlineAfter(DateTime now) {
    final values = <DateTime>[
      if (expiresAt?.isAfter(now) == true) expiresAt!,
      for (final feed in feeds)
        if (MaterialMarketQuote(
              priceMap(feed['latestQuote']),
            ).expiresAt?.isAfter(now) ==
            true)
          MaterialMarketQuote(priceMap(feed['latestQuote'])).expiresAt!,
    ];
    return values.isEmpty
        ? null
        : values.reduce((a, b) => a.isBefore(b) ? a : b);
  }

  static DateTime? _utc(Object? input) {
    final date = DateTime.tryParse(input?.toString() ?? '');
    return date?.isUtc == true ? date : null;
  }
}
