/// Exact fixed-scale decimal helpers shared by feature modules.
///
/// Decimal text remains authoritative until an explicit fixed-scale [BigInt]
/// conversion, avoiding binary floating-point round trips for money values.
const financeAmountScale = 24;
const financeRateScale = 6;

/// Finite products retain every input digit. This is a reference calculation;
/// actual document and bank amounts remain their own recorded facts.
String? financeExactMultiplyTexts(Iterable<String?> inputs) {
  var coefficient = BigInt.one;
  var scale = 0;
  for (final input in inputs) {
    if (input == null) return null;
    final match = RegExp(
      r'^([+-]?)(\d+)(?:\.(\d+))?$',
    ).firstMatch(input.trim());
    if (match == null) return null;
    final fraction = match.group(3) ?? '';
    coefficient *= BigInt.parse('${match.group(1)}${match.group(2)}$fraction');
    scale += fraction.length;
  }
  return financeExactDecimalFromUnits(coefficient, scale: scale);
}

/// Add recorded original or derived amounts at their full common scale.
/// Missing or invalid facts remain unavailable instead of silently becoming 0.
String? financeExactSumTexts(Iterable<String?> inputs) {
  final values = <String>[];
  var scale = 0;
  for (final input in inputs) {
    final value = financeExactDecimal(input);
    if (value == null) return null;
    values.add(value);
    final point = value.indexOf('.');
    final fraction = point < 0 ? 0 : value.length - point - 1;
    if (fraction > scale) scale = fraction;
  }
  var sum = BigInt.zero;
  for (final value in values) {
    sum += financeExactDecimalUnits(value, scale: scale)!;
  }
  return financeExactDecimalFromUnits(sum, scale: scale);
}

String? _canonicalDecimalText(String? value) {
  final raw = financeExactDecimal(value);
  if (raw == null || !raw.contains('.')) return raw;
  var canonical = raw;
  while (canonical.endsWith('0')) {
    canonical = canonical.substring(0, canonical.length - 1);
  }
  return canonical.endsWith('.')
      ? canonical.substring(0, canonical.length - 1)
      : canonical;
}

/// Actual financial inputs have an explicit 24-place bound; derived book
/// amounts keep their full text. Quantity helpers retain their four-place default.
BigInt? financeAmountUnits(String? raw) => financeExactDecimalUnits(
  _canonicalDecimalText(raw),
  scale: financeAmountScale,
);

String financeAmountFromUnits(BigInt units) {
  var result = financeExactDecimalFromUnits(units, scale: financeAmountScale);
  final minimumLength = result.indexOf('.') + 5;
  while (result.length > minimumLength && result.endsWith('0')) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}

String financeAmountMoneyDisplay(BigInt units) =>
    financeExactMoneyDisplay(financeAmountFromUnits(units));

/// A fixed financial representation is permitted only when it loses no value.
/// The older productUnits rounding contract remains untouched for quantities.
BigInt? financeExactProductUnitsLossless(
  String? left,
  String? right, {
  int leftScale = financeAmountScale,
  int rightScale = financeRateScale,
  int outputScale = financeAmountScale,
}) {
  if (financeExactDecimalUnits(_canonicalDecimalText(left), scale: leftScale) ==
          null ||
      financeExactDecimalUnits(
            _canonicalDecimalText(right),
            scale: rightScale,
          ) ==
          null) {
    return null;
  }
  return financeExactDecimalUnits(
    _canonicalDecimalText(financeExactMultiplyTexts([left, right])),
    scale: outputScale,
  );
}

String? financeExactDecimal(Object? value) {
  if (value == null) return null;
  final text = value.toString().trim();
  if (text.isEmpty) return null;
  return RegExp(r'^-?\d+(?:\.\d+)?$').hasMatch(text) ? text : null;
}

BigInt? financeExactDecimalUnits(String? raw, {int scale = 4}) {
  if (raw == null || scale < 0) return null;
  final match = RegExp(r'^(-?)(\d+)(?:\.(\d+))?$').firstMatch(raw.trim());
  if (match == null) return null;
  final fraction = match.group(3) ?? '';
  if (fraction.length > scale) return null;
  final factor = BigInt.from(10).pow(scale);
  final padded = fraction.padRight(scale, '0');
  final units =
      BigInt.parse(match.group(2)!) * factor +
      (padded.isEmpty ? BigInt.zero : BigInt.parse(padded));
  return match.group(1) == '-' ? -units : units;
}

BigInt? financeExactProductUnits(
  String? left,
  String? right, {
  int leftScale = 4,
  int rightScale = 6,
  int outputScale = 4,
}) {
  final leftUnits = financeExactDecimalUnits(left, scale: leftScale);
  final rightUnits = financeExactDecimalUnits(right, scale: rightScale);
  if (leftUnits == null || rightUnits == null) return null;
  final reduceScale = leftScale + rightScale - outputScale;
  if (reduceScale < 0) {
    return leftUnits * rightUnits * BigInt.from(10).pow(-reduceScale);
  }
  final divisor = BigInt.from(10).pow(reduceScale);
  final product = leftUnits * rightUnits;
  final negative = product.isNegative;
  final absolute = product.abs();
  var rounded = absolute ~/ divisor;
  final remainder = absolute % divisor;
  if (remainder * BigInt.two >= divisor) rounded += BigInt.one;
  return negative ? -rounded : rounded;
}

String financeExactUnitsMoneyDisplay(BigInt units, {int scale = 4}) =>
    financeExactMoneyDisplay(financeExactDecimalFromUnits(units, scale: scale));

String financeExactDecimalFromUnits(BigInt units, {int scale = 4}) {
  final negative = units.isNegative;
  final absolute = units.abs();
  final factor = BigInt.from(10).pow(scale);
  final whole = absolute ~/ factor;
  if (scale == 0) return '${negative ? '-' : ''}$whole';
  final fraction = (absolute % factor).toString().padLeft(scale, '0');
  return '${negative ? '-' : ''}$whole.$fraction';
}

String financeExactMoneyDisplay(String? raw) {
  final text = financeExactDecimal(raw);
  if (text == null) return '—';
  final negative = text.startsWith('-');
  final unsigned = negative ? text.substring(1) : text;
  final parts = unsigned.split('.');
  var fraction = parts.length == 1 ? '' : parts[1];
  while (fraction.length > 2 && fraction.endsWith('0')) {
    fraction = fraction.substring(0, fraction.length - 1);
  }
  fraction = fraction.padRight(2, '0');
  return '${negative ? '-' : ''}${parts.first}.$fraction';
}
