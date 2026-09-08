import '../formatters/exact_decimal.dart';

/// Reads additive server decimal-text properties without converting them through
/// a binary number. Legacy numeric properties remain display compatibility only.
Map<String, String> readExactDecimalTexts(Map<String, dynamic> json) => {
  for (final entry in json.entries)
    if (entry.key.endsWith('Exact') && entry.value is String)
      entry.key.substring(0, entry.key.length - 5): entry.value as String,
};

/// Exact preview text for decimal inputs. This performs no rounding and is not
/// a replacement for the finance-confirmed actual document amount.
String? multiplyDecimalTexts(Iterable<String> inputs) =>
    financeExactMultiplyTexts(inputs);
