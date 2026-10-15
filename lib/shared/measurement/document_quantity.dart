import '../formatters/exact_decimal.dart';

/// Command quantities must come from decimal text, never a decoded double.
/// Numeric DTO properties remain available for display and weight estimates.
String? recordedDocumentDecimal(Map<String, dynamic> json, String key) {
  final value = json.containsKey('${key}Exact')
      ? json['${key}Exact']
      : json[key];
  return value is String ? financeExactDecimal(value) : null;
}

String? nonNegativeDocumentQuantityText(String raw) {
  final text = financeExactDecimal(raw);
  final units = financeExactDecimalUnits(text);
  if (units == null ||
      units < BigInt.zero ||
      units >= BigInt.from(10).pow(18)) {
    return null;
  }
  return financeExactTrimmed(text!);
}

/// NUMERIC(18,4) input remains decimal text until the server validates it.
/// A binary number cannot preserve every valid 14-integer/4-fraction quantity.
String? positiveDocumentQuantityText(String raw) {
  final text = financeExactDecimal(raw);
  final units = financeExactDecimalUnits(text);
  if (units == null ||
      units <= BigInt.zero ||
      units >= BigInt.from(10).pow(18)) {
    return null;
  }
  return financeExactTrimmed(text);
}
