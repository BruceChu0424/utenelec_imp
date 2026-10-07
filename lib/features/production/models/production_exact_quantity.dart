import '../../../shared/formatters/exact_decimal.dart';

/// Review facts retain their original decimal text. Already-rounded large
/// legacy JSON numbers remain unknown instead of being reconstructed.
String? productionExactQuantityText(Object? value, {int scale = 4}) {
  final safeLimit = scale > 4 ? 1000000 : 10000000000;
  if (value is num && (!value.isFinite || value.abs() >= safeLimit)) {
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

/// Small legacy wire values remain numbers. Large authoritative decimal text
/// crosses JSON as text, including on JavaScript clients; never recover it from
/// an already-rounded number. The server binds both forms to BigDecimal.
Object productionQuantityWire(Object? value, {int scale = 4}) {
  final text = productionExactQuantityText(value, scale: scale);
  if (text == null) throw const FormatException('数量缺少精确原文，请重新读取或填写');
  final number = double.parse(text);
  return productionExactQuantityText(number, scale: scale) == text
      ? number
      : text;
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
