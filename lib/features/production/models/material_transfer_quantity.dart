import 'production_exact_quantity.dart';

/// Transfer capacities and commands retain 40 integer and 24 fractional digits.
/// Large legacy numbers require their exact original text.
BigInt? materialTransferUnits(Object? value, {bool positive = false}) {
  final units = productionExactQuantityUnits(value);
  if (units == null ||
      units > productionQuantityMaxUnits ||
      (positive && units == BigInt.zero)) {
    return null;
  }
  return units;
}

String materialTransferText(BigInt units) =>
    productionQuantityTextFromUnits(units);

Object materialTransferWire(Object value) {
  final units = materialTransferUnits(value, positive: true);
  if (units == null) {
    throw const FormatException('数量必须大于0，最多40位整数和24位小数，且保留精确原文');
  }
  return productionQuantityWire(materialTransferText(units));
}

Map<String, String> materialTransferExactFacts(Object? value) => value is Map
    ? Map.unmodifiable({
        for (final entry in value.entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value as String,
      })
    : const {};
