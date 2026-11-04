// Actual kilogram facts retain finite decimal digits. Unit division requires
// a current explicit precision choice when it cannot be represented exactly.
import '../../core/formatters/exact_number_text.dart';
import '../formatters/exact_decimal.dart';

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

  String get kgPerUnitText => _factorText;
  String? toKgText(Object? value) {
    final raw = _weightDecimal(value);
    if (raw == null || raw.startsWith('-')) return null;
    return financeExactTrimmed(financeExactMultiplyTexts([raw, _factorText]));
  }

  FinanceExactDivision fromKgText(
    Object? kg, {
    int? precisionScale,
    String? precisionRounding,
  }) => financeExactDivideTexts(
    _weightDecimal(kg),
    _factorText,
    maxScale: 4096,
    choiceScale: precisionScale,
    choiceRounding: precisionRounding,
  );

  /// Numeric compatibility for estimates only; document writers use decimal text.
  double toKg(double value) => double.parse(toKgText(value)!);
  double fromKg(double kg) {
    final value = fromKgText(kg).text;
    if (value == null) throw const FormatException('本次重量单位换算需要明确选择精度');
    return double.parse(value);
  }

  double toKgLine(double value) => toKg(value);
  double? kgLineFromText(String text) {
    final value = toKgText(text);
    return value == null ? null : double.parse(value);
  }

  /// Explicit kg suffix retains the original fact until display precision is
  /// chosen. Normalizing this view must never rewrite the actual kg fact.
  String editText(Object kg, {int? precisionScale, String? precisionRounding}) {
    final value = fromKgText(
      kg,
      precisionScale: precisionScale,
      precisionRounding: precisionRounding,
    ).text;
    return value ?? '${financeExactTrimmed(_weightDecimal(kg)) ?? ''} kg';
  }

  String format(
    Object kg, {
    bool withSymbol = true,
    int? precisionScale,
    String? precisionRounding,
  }) {
    final value = fromKgText(
      kg,
      precisionScale: precisionScale,
      precisionRounding: precisionRounding,
    ).text;
    if (value == null) {
      return '${exactNumberDisplay(kg, groupThousands: true) ?? '—'} kg（$symbol换算待选精度）';
    }
    final number = exactNumberDisplay(value, groupThousands: true)!;
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
  WeightUnit unitFor(Object kg) {
    final fixed = unit;
    if (fixed != null) return fixed;
    final text = _weightDecimal(kg)?.replaceFirst('-', '');
    if (text == null) return WeightUnit.kg;
    final parts = text.split('.'),
        scale = parts.length > 1 ? parts[1].length : 0;
    final exact = financeExactDecimalUnits(text, scale: scale)!;
    if (exact == BigInt.zero) return WeightUnit.kg;
    final factor = BigInt.from(10).pow(scale);
    if (exact < factor) return WeightUnit.g;
    if (exact < factor * BigInt.from(1000)) return WeightUnit.kg;
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
  Object? kg, {
  WeightDisplay display = WeightDisplay.auto,
  bool withSymbol = true,
}) {
  if (kg == null || _weightDecimal(kg) == null) return '—';
  return display.unitFor(kg).format(kg, withSymbol: withSymbol);
}

/// 幂等键/指纹里的重量片段: 千克去尾零的纯文本 (如 `0.85`、`12`), null -> 空串。
/// 与服务端 stripTrailingZeros().toPlainString() 同形态, 各页面 canonical key 共用。
String weightKeyPart(Object? kg) =>
    financeExactTrimmed(_weightDecimal(kg)) ?? '';

/// Legacy estimate compatibility. Actual facts are never quantized here.
double? roundKgLine(double? kg) => kg == null || !kg.isFinite ? null : kg;

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

  /// 单据行千克完整乘积；存储边界由本次明确精度决定。
  String get kgText => unit.toKgText(numberText)!;
  double get kgLine => double.parse(kgText);

  /// 精确千克 (不舍入, 抽样/估算用)。
  double get kg => double.parse(kgText);
}

/// 解析带单位后缀的重量输入; 空串/非法/负数返回 null。
///
/// 认得: `850g` `1.2t` `3斤` `2lb` `0.5 kg` `1,200 g` `12`(按 [defaultUnit])、全角数字与字母。
WeightInput? parseWithSuffix(String text, WeightUnit defaultUnit) {
  final normalized = _halfWidth(
    text,
  ).replaceAll(RegExp(r'\s'), '').replaceAll('，', ',').toLowerCase();
  if (normalized.isEmpty) return null;
  final match = RegExp(
    r'^((?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d*)?|\.\d+)([a-z一-龥]*)$',
  ).firstMatch(normalized);
  if (match == null) return null;
  final numberText = match.group(1)!.replaceAll(',', '');
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

String? _weightDecimal(Object? value) {
  if (value is String) {
    var raw = value.trim();
    if (RegExp(r'^\.\d+$').hasMatch(raw)) raw = '0$raw';
    if (RegExp(r'^\d+\.$').hasMatch(raw)) {
      raw = raw.substring(0, raw.length - 1);
    }
    return financeExactDecimal(raw);
  }
  return financeExactDecimal(value);
}
