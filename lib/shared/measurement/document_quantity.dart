import '../formatters/exact_decimal.dart';

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
