import '../formatters/exact_decimal.dart';

/// Command quantities must come from decimal text, never a decoded double.
/// Numeric DTO properties remain available for display and weight estimates.
String? recordedDocumentDecimal(Map<String, dynamic> json, String key) {
  final value = json.containsKey('${key}Exact')
      ? json['${key}Exact']
      : json[key];
  return value is String ? financeExactDecimal(value) : null;
}

/// Read compatibility only. Native commands use [recordedDocumentDecimal] so
/// an older binary numeric response cannot authorize a new exact write.
Map<String, String?> recordedDecimalFields(
  Map<String, dynamic> json,
  Iterable<String> keys,
) => Map.unmodifiable({
  for (final key in keys)
    key: financeExactDecimal(
      json.containsKey('${key}Exact') ? json['${key}Exact'] : json[key],
    ),
});

String? nonNegativeDocumentQuantityText(String raw) {
  final text = financeExactTrimmed(financeExactDecimal(raw));
  final units = financeExactDecimalUnits(text, scale: 24);
  if (units == null ||
      units < BigInt.zero ||
      units >= BigInt.from(10).pow(64)) {
    return null;
  }
  return financeExactTrimmed(text!);
}

/// 40-integer/24-fraction input remains decimal text until the server validates it.
/// A binary number cannot preserve every valid 40-integer/24-fraction quantity.
String? positiveDocumentQuantityText(String raw) {
  final text = financeExactTrimmed(financeExactDecimal(raw));
  final units = financeExactDecimalUnits(text, scale: 24);
  if (units == null ||
      units <= BigInt.zero ||
      units >= BigInt.from(10).pow(64)) {
    return null;
  }
  return financeExactTrimmed(text);
}
