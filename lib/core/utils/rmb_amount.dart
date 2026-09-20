// 人民币大写金额（打印报销单/票据用）。
// 口径：《支付结算办法》（银发〔1997〕393 号）附一：
// - 数字用壹贰叁肆伍陆柒捌玖拾佰仟万亿，禁用一二三和「毛」代「角」；
// - 大写前冠「人民币」且紧接填写；
// - 到「元」为止写「整」，到「角」且无「分」也写「整」，有「分」不写「整」；
// - 大小写必须一致。
// 单测：test/core/utils/rmb_amount_test.dart
library;

const String _kDigits = '零壹贰叁肆伍陆柒捌玖';
const List<String> _kFourUnits = ['', '拾', '佰', '仟'];
const List<String> _kGroupUnits = ['', '万', '亿', '万亿'];

/// 金额 → 「人民币壹万零贰佰零叁元伍角」形态的大写。
/// 输入四舍五入到分；负数/非有限数返回空串（报销域不会出现）。
String rmbCapital(num amount) {
  if (!amount.isFinite || amount < 0 || amount >= 1e16) return '';
  final int cents = (amount.toDouble() * 100).round();
  if (cents == 0) return '人民币零元整';

  final int yuan = cents ~/ 100;
  final int jiao = (cents % 100) ~/ 10;
  final int fen = cents % 10;

  final buffer = StringBuffer('人民币');
  if (yuan > 0) {
    buffer
      ..write(_yuanText(yuan))
      ..write('元');
  }

  if (jiao == 0 && fen == 0) {
    buffer.write('整');
    return buffer.toString();
  }
  if (jiao > 0) {
    buffer.write('${_kDigits[jiao]}角');
  } else if (fen > 0 && yuan > 0) {
    // 角位为零、分位有数：元与分之间补「零」（壹拾元零伍分）。
    buffer.write('零');
  }
  if (fen > 0) {
    buffer.write('${_kDigits[fen]}分');
  }
  return buffer.toString();
}

/// 整数元部分（不含「元」字）：万亿以内按四位分段，段内零只补一个，
/// 段间低位段不足一千或隔了整零段时补一个「零」（壹万零壹 / 壹佰万零壹拾）。
String _yuanText(int yuan) {
  if (yuan == 0) return '零';
  final groups = <int>[];
  var rest = yuan;
  while (rest > 0) {
    groups.add(rest % 10000);
    rest ~/= 10000;
  }
  final buffer = StringBuffer();
  var skippedZeroGroup = false;
  for (var i = groups.length - 1; i >= 0; i--) {
    final four = groups[i];
    if (four == 0) {
      skippedZeroGroup = true;
      continue;
    }
    if (buffer.isNotEmpty && (four < 1000 || skippedZeroGroup)) {
      buffer.write('零');
    }
    buffer.write(_fourDigits(four));
    buffer.write(_kGroupUnits[i]);
    skippedZeroGroup = false;
  }
  return buffer.toString();
}

/// 四位段内读法（1–9999）：零只补一个、不占单位（1005 → 壹仟零伍）。
String _fourDigits(int four) {
  var result = '';
  var zeroPending = false;
  for (var i = 3; i >= 0; i--) {
    final digit = (four ~/ _pow10(i)) % 10;
    if (digit == 0) {
      if (result.isNotEmpty) zeroPending = true;
      continue;
    }
    if (zeroPending) {
      result += '零';
      zeroPending = false;
    }
    result += _kDigits[digit] + _kFourUnits[i];
  }
  return result;
}

int _pow10(int exponent) {
  var value = 1;
  for (var i = 0; i < exponent; i++) {
    value *= 10;
  }
  return value;
}

/// Parse a currency input without binary floating point rounding or exponent notation.
/// Values are bounded to the expense database amount precision, numeric(12, 2).
int? parseExpenseAmountCents(String input, {bool allowZero = false}) {
  final text = input.trim();
  if (!RegExp(r'^\d{1,10}(?:\.\d{1,2})?$').hasMatch(text)) return null;
  final parts = text.split('.');
  final cents =
      int.parse(parts.first) * 100 +
      (parts.length == 1 ? 0 : int.parse(parts[1].padRight(2, '0')));
  if (cents > 999999999999 || (allowZero ? cents < 0 : cents <= 0)) return null;
  return cents;
}
