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

/// Native command quantities and their source bounds use the same 40/24
/// representation. Display estimates never participate in this conversion.
BigInt? nonNegativeDocumentQuantityUnits(String? raw) =>
    _documentQuantityValue(raw)?.units;

({String text, BigInt units})? _documentQuantityValue(
  String? raw, {
  int integerDigits = 40,
  int fractionDigits = 24,
}) {
  if (integerDigits < 1 ||
      integerDigits > 40 ||
      fractionDigits < 0 ||
      fractionDigits > 24) {
    throw ArgumentError('单据十进制边界超出公共支持范围');
  }
  final text = financeExactTrimmed(financeExactDecimal(raw));
  if (text == null) return null;
  final units = financeExactDecimalUnits(text, scale: 24);
  if (units == null ||
      units < BigInt.zero ||
      units >= BigInt.from(10).pow(integerDigits + 24) ||
      (fractionDigits < 24 &&
          financeExactDecimalUnits(text, scale: fractionDigits) == null)) {
    return null;
  }
  return (text: text, units: units);
}

String? nonNegativeDocumentQuantityText(
  String raw, {
  int integerDigits = 40,
  int fractionDigits = 24,
}) => _documentQuantityValue(
  raw,
  integerDigits: integerDigits,
  fractionDigits: fractionDigits,
)?.text;

/// 40-integer/24-fraction input remains decimal text until the server validates it.
/// A binary number cannot preserve every valid 40-integer/24-fraction quantity.
String? positiveDocumentQuantityText(
  String raw, {
  int integerDigits = 40,
  int fractionDigits = 24,
}) {
  final value = _documentQuantityValue(
    raw,
    integerDigits: integerDigits,
    fractionDigits: fractionDigits,
  );
  return value == null || value.units == BigInt.zero ? null : value.text;
}

/// Material commands share the service's positive 14/4 value boundary while
/// retaining each caller's original syntax and entered text. General document
/// quantities still use 40/24.
String? positiveMaterialCommandQuantityText(
  String raw, {
  bool plainDecimalOnly = true,
}) {
  final text = raw.trim();
  if (plainDecimalOnly && !RegExp(r'^\d+(\.\d+)?$').hasMatch(text)) {
    return null;
  }
  return positiveDocumentQuantityText(
            text,
            integerDigits: 14,
            fractionDigits: 4,
          ) ==
          null
      ? null
      : text;
}
