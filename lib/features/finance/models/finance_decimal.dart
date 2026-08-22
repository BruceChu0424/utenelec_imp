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
