import '../../../shared/formatters/exact_decimal.dart';

/// The existing quantity and rate columns both have 18 decimal storage digits.
/// Quantities use four fractional places; unit rates use six.
final productionQuantityMaxUnits = BigInt.from(10).pow(18) - BigInt.one;

/// Review facts retain their original decimal text. Already-rounded large
/// legacy JSON numbers remain unknown instead of being reconstructed.
String? productionExactQuantityText(Object? value, {int scale = 4}) {
  final safeLimit = scale > 4 ? 1000000 : 10000000000;
  if (value is num && (!value.isFinite || value.abs() >= safeLimit)) {
    return null;
  }
  final input = value is String ? value.trim() : value;
  final raw = financeExactDecimal(
    input is String && RegExp(r'^\.\d+$').hasMatch(input)
        ? '0$input'
        : input is String && RegExp(r'^\d+\.$').hasMatch(input)
        ? input.substring(0, input.length - 1)
        : input,
  );
  final units = financeExactDecimalUnits(
    raw == null ? null : _canonical(raw),
    scale: scale,
  );
  if (units == null || units.isNegative) return null;
  return _canonical(financeExactDecimalFromUnits(units, scale: scale));
}

/// A trusted quantity in fixed decimal units. Large legacy JSON numbers remain
/// unknown; only their original exact text can participate in a capacity check.
BigInt? productionExactQuantityUnits(Object? value, {int scale = 4}) {
  final text = productionExactQuantityText(value, scale: scale);
  return text == null ? null : financeExactDecimalUnits(text, scale: scale);
}

String productionQuantityTextFromUnits(BigInt units, {int scale = 4}) =>
    _canonical(financeExactDecimalFromUnits(units, scale: scale));

String? productionQuantityWithUnit(Object? value, String? unit) {
  final text = productionExactQuantityText(value);
  if (text == null) return null;
  final suffix = unit?.trim() ?? '';
  return suffix.isEmpty ? text : '$text $suffix';
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
