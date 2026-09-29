// 重量单位 (ADR-135 §1): 封闭目录, 存储一律千克(kg)。
//
// 与服务端 com.uten.imp.common.measure.WeightUnit 同一张表、同一套舍入:
// - 单据明细/采集行重量一律换成 kg 后 HALF_UP 保留 4 位小数 (0.1 g) 再发给服务端,
//   服务端再校验一次 (>= 0, 小数 <= 4 位); 输入 0 视为「没称」(null)。
// - 换算用十进制精确乘法 ([_Dec]), 不走 double 乘法——double 在 .5 边界会误舍
//   (如 1.00005 x 10000 = 10000.499999...), 与服务端 BigDecimal 结果对不上。
// - 显示: [WeightDisplay.auto] 按量级自动选单位 (< 1 kg -> 克, < 1000 kg -> 千克,
//   其余 -> 吨), 去掉多余的 0; null 显示「—」(由调用方决定是否改成「未称」)。
import 'package:intl/intl.dart';

/// 重量单位 (与服务端枚举同码同系数)。
enum WeightUnit {
  g('G', '克', 'g', '0.001', 0.001),
  kg('KG', '千克', 'kg', '1', 1),
  t('T', '吨', 't', '1000', 1000),
  jin('JIN', '斤', '斤', '0.5', 0.5),
  lb('LB', '磅', 'lb', '0.45359237', 0.45359237),
  oz('OZ', '盎司', 'oz', '0.028349523125', 0.028349523125);

  const WeightUnit(
    this.code,
    this.label,
    this.symbol,
    this._factorText,
    this.kgPerUnit,
  );

  /// 服务端码 (G/KG/T/JIN/LB/OZ), 偏好与接口都用它。
  final String code;

  /// 中文名 (克/千克/吨/斤/磅/盎司), 下拉与说明用。
  final String label;

  /// 紧凑符号 (g/kg/t/斤/lb/oz), 数值后缀与表头用。
  final String symbol;

  final String _factorText;

  /// 1 个本单位 = 多少千克。
  final double kgPerUnit;

  /// 本单位数值 -> 千克 (不舍入, 显示/估算用)。
  double toKg(double value) => value * kgPerUnit;

  /// 千克 -> 本单位数值 (不舍入, 显示用)。
  double fromKg(double kg) => kg / kgPerUnit;

  /// 本单位数值 -> 单据行千克 (十进制精确乘法后 HALF_UP 4 位; 与服务端 toKgLine 一致)。
  /// 非有限数原样返回 (调用方先校验)。
  double toKgLine(double value) {
    final dec = _Dec.parse(_plain(value));
    if (dec == null) return value;
    return (dec * _Dec.parse(_factorText)!).roundHalfUp(4).toDouble();
  }

  /// 本单位数值文本 -> 单据行千克; 文本不是非负十进制数时返回 null。
  double? kgLineFromText(String numberText) {
    final dec = _Dec.parse(numberText);
    if (dec == null || dec.isNegative) return null;
    return (dec * _Dec.parse(_factorText)!).roundHalfUp(4).toDouble();
  }

  /// 可编辑文本 (无千分位、去尾零): 把千克值写回本单位的输入框。
  /// 小数位上限保证 4 位 kg 精度不丢 (克 1 位、吨 7 位、其余 4 位)。
  String editText(double kg) {
    final value = fromKg(kg);
    if (!value.isFinite) return '';
    final digits = switch (this) {
      WeightUnit.g => 1,
      WeightUnit.t => 7,
      WeightUnit.oz => 3,
      _ => 4,
    };
    return _Dec.parse(_plain(value))!.roundHalfUp(digits).toPlainString();
  }

  /// 本单位显示 (千分位、去尾零, 带符号): 如 `12.5 kg`、`850 g`。
  String format(double kg, {bool withSymbol = true}) {
    final number = _displayFormat(this).format(fromKg(kg));
    return withSymbol ? '$number $symbol' : number;
  }

  /// 按码/符号/中文名解析 (大小写不敏感, 含 kgs/公斤/lbs 等常见写法); 不认识返回 null。
  static WeightUnit? parse(String? raw) {
    final key = raw?.trim().toLowerCase();
    if (key == null || key.isEmpty) return null;
    return _aliases[key];
  }

  /// 按服务端码取单位; 不认识时用 [fallback]。
  static WeightUnit fromCode(String? code, {WeightUnit fallback = kg}) =>
      parse(code) ?? fallback;
}

const Map<String, WeightUnit> _aliases = {
  'g': WeightUnit.g,
  'gram': WeightUnit.g,
  'grams': WeightUnit.g,
  '克': WeightUnit.g,
  'kg': WeightUnit.kg,
  'kgs': WeightUnit.kg,
  '千克': WeightUnit.kg,
  '公斤': WeightUnit.kg,
  't': WeightUnit.t,
  'ton': WeightUnit.t,
  'tons': WeightUnit.t,
  '吨': WeightUnit.t,
  'jin': WeightUnit.jin,
  '斤': WeightUnit.jin,
  '市斤': WeightUnit.jin,
  'lb': WeightUnit.lb,
  'lbs': WeightUnit.lb,
  '磅': WeightUnit.lb,
  'oz': WeightUnit.oz,
  '盎司': WeightUnit.oz,
};

/// 重量显示单位: 自动 (按量级) 或固定某个单位。偏好里存 [code] (AUTO/G/KG/...)。
enum WeightDisplay {
  auto('AUTO', '自动', null),
  g('G', '克', WeightUnit.g),
  kg('KG', '千克', WeightUnit.kg),
  t('T', '吨', WeightUnit.t),
  jin('JIN', '斤', WeightUnit.jin),
  lb('LB', '磅', WeightUnit.lb),
  oz('OZ', '盎司', WeightUnit.oz);

  const WeightDisplay(this.code, this.label, this.unit);

  final String code;
  final String label;

  /// 固定单位; [auto] 为 null。
  final WeightUnit? unit;

  /// 该千克值实际用哪个单位显示 (自动档: < 1 kg -> 克, < 1000 kg -> 千克, 否则吨; 0 用千克)。
  WeightUnit unitFor(double kg) {
    final fixed = unit;
    if (fixed != null) return fixed;
    final abs = kg.abs();
    if (abs == 0) return WeightUnit.kg;
    if (abs < 1) return WeightUnit.g;
    if (abs < 1000) return WeightUnit.kg;
    return WeightUnit.t;
  }

  /// 导出/接口用的固定单位 (自动档一律回落千克, 数值列不混单位)。
  WeightUnit get exportUnit => unit ?? WeightUnit.kg;

  static WeightDisplay fromCode(
    String? code, {
    WeightDisplay fallback = WeightDisplay.auto,
  }) {
    final key = code?.trim().toUpperCase();
    for (final d in WeightDisplay.values) {
      if (d.code == key) return d;
    }
    return fallback;
  }

  static WeightDisplay of(WeightUnit unit) =>
      WeightDisplay.values.firstWhere((d) => d.unit == unit);
}

/// 千克值 -> 显示文本 (如 `3.52 t`、`850 g`); null / 非有限数 -> `—`。
String formatWeight(
  double? kg, {
  WeightDisplay display = WeightDisplay.auto,
  bool withSymbol = true,
}) {
  if (kg == null || !kg.isFinite) return '—';
  return display.unitFor(kg).format(kg, withSymbol: withSymbol);
}

/// 幂等键/指纹里的重量片段: 千克去尾零的纯文本 (如 `0.85`、`12`), null -> 空串。
/// 与服务端 stripTrailingZeros().toPlainString() 同形态, 各页面 canonical key 共用。
String weightKeyPart(double? kg) {
  if (kg == null || !kg.isFinite) return '';
  return _Dec.parse(_plain(kg))!.roundHalfUp(4).toPlainString();
}

/// 千克值 HALF_UP 保留 4 位 (单据行精度); null / 非有限数原样返回 null。
double? roundKgLine(double? kg) {
  if (kg == null || !kg.isFinite) return null;
  return _Dec.parse(_plain(kg))!.roundHalfUp(4).toDouble();
}

/// 带单位后缀的一次输入 (如 `850g`、`1.2t`、`3斤`、`12`)。
class WeightInput {
  const WeightInput({
    required this.numberText,
    required this.value,
    required this.unit,
    required this.explicitUnit,
  });

  /// 规范化后的数值文本 (半角、无千分位)。
  final String numberText;
  final double value;
  final WeightUnit unit;

  /// 是否带了单位后缀 (没带 = 按列/默认单位理解)。
  final bool explicitUnit;

  /// 单据行千克 (HALF_UP 4 位)。
  double get kgLine => unit.kgLineFromText(numberText)!;

  /// 精确千克 (不舍入, 抽样/估算用)。
  double get kg => unit.toKg(value);
}

/// 解析带单位后缀的重量输入; 空串/非法/负数返回 null。
///
/// 认得: `850g` `1.2t` `3斤` `2lb` `0.5 kg` `1,200 g` `12`(按 [defaultUnit])、全角数字与字母。
WeightInput? parseWithSuffix(String text, WeightUnit defaultUnit) {
  final normalized = _halfWidth(
    text,
  ).replaceAll(RegExp(r'[\s,，]'), '').toLowerCase();
  if (normalized.isEmpty) return null;
  final match = RegExp(
    r'^(\d+(?:\.\d*)?|\.\d+)([a-z一-龥]*)$',
  ).firstMatch(normalized);
  if (match == null) return null;
  final numberText = match.group(1)!;
  final suffix = match.group(2)!;
  final unit = suffix.isEmpty ? defaultUnit : WeightUnit.parse(suffix);
  if (unit == null) return null;
  final value = double.tryParse(numberText);
  if (value == null || !value.isFinite || value < 0) return null;
  return WeightInput(
    numberText: numberText,
    value: value,
    unit: unit,
    explicitUnit: suffix.isNotEmpty,
  );
}

NumberFormat _displayFormat(WeightUnit unit) => switch (unit) {
  WeightUnit.g => NumberFormat('#,##0.#', 'zh_CN'),
  WeightUnit.oz => NumberFormat('#,##0.##', 'zh_CN'),
  _ => NumberFormat('#,##0.###', 'zh_CN'),
};

/// 全角数字/字母/小数点 -> 半角 (中文输入法下常见)。
String _halfWidth(String text) {
  final out = StringBuffer();
  for (final rune in text.runes) {
    if (rune >= 0xFF01 && rune <= 0xFF5E) {
      out.writeCharCode(rune - 0xFEE0);
    } else if (rune == 0x3002) {
      // 中文句号当小数点。
      out.write('.');
    } else {
      out.writeCharCode(rune);
    }
  }
  return out.toString();
}

/// double 的最短十进制文本 (避免 1e-7 这类指数形态进入十进制解析时丢精度)。
String _plain(double value) => value.toString();

/// 十进制定点数 (unscaled / 10^scale), 只服务于换算与舍入。
class _Dec {
  const _Dec(this.unscaled, this.scale);

  final BigInt unscaled;
  final int scale;

  bool get isNegative => unscaled.isNegative;

  static _Dec? parse(String raw) {
    final text = raw.trim();
    final m = RegExp(
      r'^([+-]?)(\d*)(?:\.(\d*))?(?:[eE]([+-]?\d+))?$',
    ).firstMatch(text);
    if (m == null) return null;
    final intPart = m.group(2) ?? '';
    final fracPart = m.group(3) ?? '';
    if (intPart.isEmpty && fracPart.isEmpty) return null;
    final exponent = int.tryParse(m.group(4) ?? '0') ?? 0;
    var unscaled = BigInt.parse('${intPart.isEmpty ? '0' : intPart}$fracPart');
    var scale = fracPart.length - exponent;
    if (scale < 0) {
      unscaled *= BigInt.from(10).pow(-scale);
      scale = 0;
    }
    if (m.group(1) == '-') unscaled = -unscaled;
    return _Dec(unscaled, scale);
  }

  _Dec operator *(_Dec other) =>
      _Dec(unscaled * other.unscaled, scale + other.scale);

  /// 舍入到 [target] 位小数, HALF_UP (远离零方向进位)。
  _Dec roundHalfUp(int target) {
    if (scale <= target) {
      return _Dec(unscaled * BigInt.from(10).pow(target - scale), target);
    }
    final divisor = BigInt.from(10).pow(scale - target);
    final negative = unscaled.isNegative;
    final abs = unscaled.abs();
    var quotient = abs ~/ divisor;
    final remainder = abs - quotient * divisor;
    if (remainder * BigInt.two >= divisor) quotient += BigInt.one;
    return _Dec(negative ? -quotient : quotient, target);
  }

  /// 纯文本 (去尾零, 无指数)。
  String toPlainString() {
    final negative = unscaled.isNegative;
    var digits = unscaled.abs().toString();
    if (scale > 0) {
      if (digits.length <= scale) digits = digits.padLeft(scale + 1, '0');
      final cut = digits.length - scale;
      final frac = digits.substring(cut).replaceFirst(RegExp(r'0+$'), '');
      final whole = digits.substring(0, cut);
      digits = frac.isEmpty ? whole : '$whole.$frac';
    }
    if (digits == '0') return '0';
    return negative ? '-$digits' : digits;
  }

  double toDouble() => double.parse(toPlainString());
}
