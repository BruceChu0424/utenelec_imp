import '../../../shared/formatters/exact_decimal.dart';

/// Actual quantity/rate inputs retain 24 fractional and 40 integer digits.
/// Intermediate products use both complete input scales, never a stored scale.
const productionQuantityScale = 24;
const productionProductScale = productionQuantityScale * 2;
final productionQuantityMaxUnits = BigInt.from(10).pow(64) - BigInt.one;
final productionProductFactor = BigInt.from(10).pow(productionQuantityScale);
final productionProductMaxUnits =
    BigInt.from(10).pow(40 + productionProductScale) - BigInt.one;

/// Review facts retain their original decimal text. Already-rounded large
/// legacy JSON numbers remain unknown instead of being reconstructed.
String? productionExactQuantityText(
  Object? value, {
  int scale = productionQuantityScale,
}) {
  final safeLimit = scale == 6 ? 1000000 : 10000000000;
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
BigInt? productionExactQuantityUnits(
  Object? value, {
  int scale = productionQuantityScale,
}) {
  final text = productionExactQuantityText(value, scale: scale);
  return text == null ? null : financeExactDecimalUnits(text, scale: scale);
}

String productionQuantityTextFromUnits(
  BigInt units, {
  int scale = productionQuantityScale,
}) => _canonical(financeExactDecimalFromUnits(units, scale: scale));

/// Read-only report quota preview. Original decimal facts share one subtraction
/// and the existing business tolerance; unsafe legacy numbers stay unknown.
class ProductionReportPreview {
  ProductionReportPreview({required Object? remaining, Object? draft = '0'})
    : baseUnits = productionExactQuantityUnits(remaining),
      draftUnits = productionExactQuantityUnits(draft);

  final BigInt? baseUnits;
  final BigInt? draftUnits;
  static final _threshold = productionExactQuantityUnits('0.000001')!;
  bool get known => baseUnits != null && draftUnits != null;
  BigInt? get remainingUnits {
    if (!known) return null;
    final difference = baseUnits! - draftUnits!;
    return difference.isNegative ? BigInt.zero : difference;
  }

  String? get remainingText => remainingUnits == null
      ? null
      : productionQuantityTextFromUnits(remainingUnits!);
  bool get atMostThreshold => known && remainingUnits! <= _threshold;
  bool get fullyClaimed => atMostThreshold && baseUnits! > _threshold;
  bool get draftAwaitingApproval => fullyClaimed && draftUnits! > _threshold;
}

String? productionQuantityWithUnit(Object? value, String? unit) {
  final text = productionExactQuantityText(value);
  if (text == null) return null;
  final suffix = unit?.trim() ?? '';
  return suffix.isEmpty ? text : '$text $suffix';
}

/// Small legacy wire values remain numbers. Large authoritative decimal text
/// crosses JSON as text, including on JavaScript clients; never recover it from
/// an already-rounded number. The server binds both forms to BigDecimal.
Object productionQuantityWire(
  Object? value, {
  int scale = productionQuantityScale,
}) {
  final text = productionExactQuantityText(value, scale: scale);
  if (text == null) throw const FormatException('数量缺少精确原文，请重新读取或填写');
  final number = double.parse(text);
  return productionExactQuantityText(number, scale: scale) == text
      ? number
      : text;
}

String? productionExactPercentageText(Object? rate) {
  final value = productionExactQuantityText(rate);
  return value == null
      ? null
      : _canonical(financeExactMultiplyTexts([value, '100'])!);
}

String _canonical(String text) => text.contains('.')
    ? text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')
    : text;
