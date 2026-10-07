import '../../../shared/formatters/exact_decimal.dart';

/// Review facts retain their original decimal text. Already-rounded large
/// legacy JSON numbers remain unknown instead of being reconstructed.
String? productionExactQuantityText(Object? value, {int scale = 4}) {
  if (value is num && (!value.isFinite || value.abs() >= 10000000000)) {
    return null;
  }
  final raw = financeExactDecimal(value);
  final units = financeExactDecimalUnits(
    raw == null ? null : _canonical(raw),
    scale: scale,
  );
  if (units == null || units.isNegative) return null;
  return _canonical(financeExactDecimalFromUnits(units, scale: scale));
}

String? productionExactPercentageText(Object? rate) {
  final value = productionExactQuantityText(rate, scale: 6);
  return value == null
      ? null
      : _canonical(financeExactMultiplyTexts([value, '100'])!);
}

String _canonical(String text) => text.contains('.')
    ? text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')
    : text;
