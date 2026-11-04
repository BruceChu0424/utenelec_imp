import '../../core/formatters/exact_number_text.dart';

/// Exact fixed-scale decimal helpers shared by feature modules.
///
/// Decimal text remains authoritative until an explicit fixed-scale [BigInt]
/// conversion, avoiding binary floating-point round trips for money values.
const financeAmountScale = 24;
const financeRateScale = 6;

/// Native percentage points, distinct from a stored 0..1 ratio. No projection.
({String? value, bool valid}) parseExactPercentage(String? raw) {
  final text = raw?.trim() ?? '';
  if (text.isEmpty) return (value: null, valid: true);
  final units = financeAmountUnits(text);
  if (units == null ||
      units < BigInt.zero ||
      units > BigInt.from(100) * BigInt.from(10).pow(financeAmountScale)) {
    return (value: null, valid: false);
  }
  return (value: financeExactDecimal(text), valid: true);
}

/// Finite products retain every input digit. This is a reference calculation;
/// actual document and bank amounts remain their own recorded facts.
String? financeExactMultiplyTexts(Iterable<String?> inputs) {
  var coefficient = BigInt.one;
  var scale = 0;
  for (final input in inputs) {
    if (input == null) return null;
    final parsed = financeExactDecimal(input);
    if (parsed == null) {
      return null;
    }
    final match = RegExp(r'^([+-]?)(\d+)(?:\.(\d+))?$').firstMatch(parsed);
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

BigInt? financeRateUnits(String? raw) => financeExactDecimalUnits(
  _canonicalDecimalText(raw),
  scale: financeRateScale,
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

String? financeExactDecimal(Object? value) {
  return exactNumberText(value);
}

BigInt? financeExactDecimalUnits(String? raw, {int scale = 4}) {
  if (raw == null || scale < 0) return null;
  final canonical = financeExactDecimal(raw);
  if (canonical == null) {
    return null;
  }
  final match = RegExp(r'^(-?)(\d+)(?:\.(\d+))?$').firstMatch(canonical);
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

class FinanceExactDivision {
  const FinanceExactDivision(this.text, {this.reason, this.usedChoice = false});
  final String? text;
  final String? reason;
  final bool usedChoice;
}

/// Finite divisions are exact and ignore a smaller suggested/display scale.
/// A non-finite or unsupported result needs an explicit current-user policy.
FinanceExactDivision financeExactDivideTexts(
  String? left,
  String? right, {
  int maxScale = 24,
  int? choiceScale,
  String? choiceRounding,
}) {
  final l = financeExactDecimal(left), r = financeExactDecimal(right);
  if (l == null || r == null) return const FinanceExactDivision(null);
  int scale(String value) =>
      value.contains('.') ? value.length - value.indexOf('.') - 1 : 0;
  final ls = scale(l), rs = scale(r);
  var numerator =
      financeExactDecimalUnits(l, scale: ls)! * BigInt.from(10).pow(rs);
  var denominator =
      financeExactDecimalUnits(r, scale: rs)! * BigInt.from(10).pow(ls);
  if (denominator == BigInt.zero) return const FinanceExactDivision(null);
  final negative = numerator.isNegative != denominator.isNegative;
  numerator = numerator.abs();
  denominator = denominator.abs();
  final gcd = numerator.gcd(denominator);
  numerator ~/= gcd;
  denominator ~/= gcd;
  var remaining = denominator, twos = 0, fives = 0;
  while (remaining % BigInt.two == BigInt.zero) {
    remaining ~/= BigInt.two;
    twos++;
  }
  while (remaining % BigInt.from(5) == BigInt.zero) {
    remaining ~/= BigInt.from(5);
    fives++;
  }
  final finiteScale = twos > fives ? twos : fives;
  if (remaining == BigInt.one && finiteScale <= maxScale) {
    final units = numerator * BigInt.from(10).pow(finiteScale) ~/ denominator;
    return FinanceExactDivision(
      financeExactTrimmed(
        financeExactDecimalFromUnits(
          negative ? -units : units,
          scale: finiteScale,
        ),
      ),
    );
  }
  final reason = remaining == BigInt.one
      ? 'PRECISION_LIMIT'
      : 'NON_TERMINATING';
  if (choiceScale == null ||
      choiceScale < 0 ||
      choiceScale > maxScale ||
      !const {'HALF_UP', 'DOWN'}.contains(choiceRounding)) {
    return FinanceExactDivision(null, reason: reason);
  }
  final scaled = numerator * BigInt.from(10).pow(choiceScale);
  var units = scaled ~/ denominator;
  if (choiceRounding == 'HALF_UP' &&
      (scaled % denominator) * BigInt.two >= denominator) {
    units += BigInt.one;
  }
  return FinanceExactDivision(
    financeExactTrimmed(
      financeExactDecimalFromUnits(
        negative ? -units : units,
        scale: choiceScale,
      ),
    ),
    usedChoice: true,
  );
}

/// Complete finite product in explicit output units. An unsupported scale stays
/// unavailable; this conversion never chooses a rounding policy.
BigInt? financeExactProductUnits(
  String? left,
  String? right, {
  int leftScale = 24,
  int rightScale = 24,
  int outputScale = 48,
}) {
  final l = financeExactTrimmed(left), r = financeExactTrimmed(right);
  if (financeExactDecimalUnits(l, scale: leftScale) == null ||
      financeExactDecimalUnits(r, scale: rightScale) == null) {
    return null;
  }
  return financeExactDecimalUnits(
    financeExactTrimmed(financeExactMultiplyTexts([l, r])),
    scale: outputScale,
  );
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

String financeExactMoneyDisplay(String? raw, {bool groupThousands = false}) {
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
  final whole = groupThousands
      ? parts.first.replaceAllMapped(
          RegExp(r'(\d)(?=(\d{3})+$)'),
          (match) => '${match[1]},',
        )
      : parts.first;
  return '${negative ? '-' : ''}$whole.$fraction';
}

/// 编辑页金额预览(ADR-112): 数量 × 单价(× 折扣倍率)的十进制精确乘积, 与服务端 MoneyPolicy
/// 同一口径; 折扣空或 0 按不打折。任一输入为空或不是数字时返回 null(不猜 0)。
/// 预览只用于显示, 保存请求不再带金额, 金额由服务端派生。
String? exactLineAmountText(String qty, String price, {String? discount}) {
  final q = qty.trim();
  final p = price.trim();
  if (q.isEmpty || p.isEmpty) return null;
  final factors = <String>[q, p];
  if (discount != null) {
    final d = discount.trim();
    final exact = financeExactDecimal(d);
    if (d.isNotEmpty && exact == null) return null;
    final isZero = exact != null && RegExp(r'^-?0+(\.0+)?$').hasMatch(exact);
    if (exact != null && !isZero) factors.add(exact);
  }
  return financeExactMultiplyTexts(factors);
}

/// 行金额预览合计: 只加已算出的行, 全部为空时为 0; 不经过 double。
String exactAmountSumText(Iterable<String?> amounts) =>
    financeExactSumTexts(amounts.whereType<String>()) ?? '0';

/// 数量/单价/汇率等十进制原文的展示: 去掉末尾多余的 0, 不四舍五入; 不是数字时原样返回。
String? financeExactTrimmed(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  return _canonicalDecimalText(raw) ?? raw.trim();
}
