// 中国居民身份证工具（与后端 IdCardUtil 对齐）：校验(GB11643)、反推生日/性别、脱敏。
//
// 2026-10-05 起校验给出「具体哪里不对」：[problemOf] 与后端 IdCardUtil.check 同一套
// 检查顺序、同一句话(只说位置和长度，绝不回显号码本身)。表单校验、访客预约、
// 修改证件弹窗都直接显示这句话，用户一眼知道是长度不对还是第几位不对。
//
// 每句话只在 [IdCardProblem] 里写一次：录入时的提示用 [IdCardUtils.check]，审计里
// 「证件号校验结果」存下来的问题码用 [IdCardProblem.fromCode] 还原，两处是同一句话。
import 'china_datetime.dart';

/// 身份证号具体哪里不对(与后端 IdCardProblem 一一对应)。
///
/// [code] 是稳定的机器码，员工档案里存的证件号校验结果就是它；[message] 是给人看的
/// 说明，只写位置和长度，绝不带号码本身。同一个 code 永远对应同一句说明。
final class IdCardProblem {
  const IdCardProblem._(this.code, this.message);

  /// 长度不对：长度按字符(码点)数。
  IdCardProblem.length(int actual)
    : this._('$_lengthPrefix$actual', '身份证号应为18位，当前为$actual位');

  /// 第 [position] 位(从 1 数)字符不对：前 17 位只能是数字，第 18 位可以是 X。
  IdCardProblem.character(int position)
    : this._(
        '$_characterPrefix$position',
        position == 18 ? '身份证号第18位只能是数字或X' : '身份证号第$position位不是数字(只有第18位可以是X)',
      );

  final String code;
  final String message;

  static const _lengthPrefix = 'length:';
  static const _characterPrefix = 'character:';

  static const empty = IdCardProblem._('empty', '身份证号不能为空');
  static const birthDate = IdCardProblem._('birth_date', '身份证号第7-14位不是有效的出生日期');
  static const birthTooEarly = IdCardProblem._(
    'birth_too_early',
    '身份证号第7-14位的出生日期早于1800年',
  );
  static const birthFuture = IdCardProblem._(
    'birth_future',
    '身份证号第7-14位的出生日期晚于今天',
  );
  static const regionCode = IdCardProblem._('region_code', '身份证号前6位地区码不能全为0');
  static const sequenceCode = IdCardProblem._(
    'sequence_code',
    '身份证号第15-17位顺序码不能全为0',
  );
  static const checkDigit = IdCardProblem._(
    'check_digit',
    '身份证号第18位校验码与前17位不符，通常是某一位数字录错或相邻两位颠倒，请对照证件逐位核对',
  );

  static const _fixed = [
    empty,
    birthDate,
    birthTooEarly,
    birthFuture,
    regionCode,
    sequenceCode,
    checkDigit,
  ];

  /// 按存下来的 code 还原同一句说明；不认识的 code 返回 null(调用方自己决定兜底文案)。
  ///
  /// 与后端 IdCardProblem.fromCode 同口径：length 只认 1-3 位数字且不是 18，
  /// character 只认 1-2 位数字的 1 到 18。
  static IdCardProblem? fromCode(String? code) {
    if (code == null) return null;
    for (final problem in _fixed) {
      if (problem.code == code) return problem;
    }
    if (code.startsWith(_lengthPrefix)) {
      final actual = _smallNumber(code.substring(_lengthPrefix.length), 3);
      return actual == null || actual == 18
          ? null
          : IdCardProblem.length(actual);
    }
    if (code.startsWith(_characterPrefix)) {
      final position = _smallNumber(code.substring(_characterPrefix.length), 2);
      return position == null || position < 1 || position > 18
          ? null
          : IdCardProblem.character(position);
    }
    return null;
  }

  /// 只接受 1 到 [maxDigits] 位的 ASCII 数字，其它一律视为不认识。
  static int? _smallNumber(String text, int maxDigits) {
    if (text.isEmpty || text.length > maxDigits) return null;
    if (!RegExp(r'^[0-9]+$').hasMatch(text)) return null;
    return int.parse(text);
  }
}

abstract final class IdCardUtils {
  static const _weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2];
  static const _check = ['1', '0', 'X', '9', '8', '7', '6', '5', '4', '3', '2'];

  /// 与后端 IdCardUtil.normalize 同口径：全角字符折成半角、去首尾空白、校验位统一大写 X；
  /// 空串返回 null。
  static String? normalize(String? raw) {
    if (raw == null) return null;
    final folded = StringBuffer();
    for (final rune in raw.runes) {
      if (rune == 0x3000) {
        folded.writeCharCode(0x20); // 全角空格
      } else if (rune >= 0xFF01 && rune <= 0xFF5E) {
        folded.writeCharCode(rune - 0xFEE0); // 全角 ASCII(数字、字母)
      } else {
        folded.writeCharCode(rune);
      }
    }
    final value = folded.toString().trim().toUpperCase();
    return value.isEmpty ? null : value;
  }

  /// 身份证号具体哪里不对的说明；合法返回 null。说明来自 [check]。
  static String? problemOf(String? raw) => check(raw)?.message;

  /// 身份证号具体哪里不对；合法返回 null。
  ///
  /// 检查顺序与问题码和后端 IdCardUtil.check 逐条一致：为空 → 长度 → 第 1-17 位数字 →
  /// 第 18 位 → 出生日期 → 早于 1800 年 → 晚于今天 → 地区码 → 顺序码 → 校验码。
  /// 长度和位置按字符(码点)数，与后端相同。说明只含位置和长度，不含号码本身，
  /// 可以直接给用户看。
  static IdCardProblem? check(String? raw) {
    final value = normalize(raw);
    if (value == null) return IdCardProblem.empty;
    final chars = value.runes.toList(growable: false);
    if (chars.length != 18) return IdCardProblem.length(chars.length);
    for (var i = 0; i < 17; i++) {
      if (!_isDigit(chars[i])) return IdCardProblem.character(i + 1);
    }
    if (!_isDigit(chars[17]) && chars[17] != 0x58) {
      return IdCardProblem.character(18);
    }
    // 到这里 18 位全是 ASCII，按下标取子串是安全的。
    final birth = _parseBirthDate(value);
    if (birth == null) return IdCardProblem.birthDate;
    if (birth.year < 1800) return IdCardProblem.birthTooEarly;
    if (birth.isAfter(ChinaDateTime.today())) return IdCardProblem.birthFuture;
    if (value.startsWith('000000')) return IdCardProblem.regionCode;
    if (value.substring(14, 17) == '000') return IdCardProblem.sequenceCode;
    var sum = 0;
    for (var i = 0; i < 17; i++) {
      sum += (value.codeUnitAt(i) - 0x30) * _weights[i];
    }
    if (_check[sum % 11] != value[17]) return IdCardProblem.checkDigit;
    return null;
  }

  static bool isValid(String? id) => problemOf(id) == null;

  static DateTime? birthDate(String id) {
    final value = id.trim();
    return value.length == 18 ? _parseBirthDate(value) : null;
  }

  /// 第 17 位奇=男 偶=女。
  static String? gender(String id) {
    if (id.length != 18) return null;
    final seq = int.tryParse(id.substring(16, 17));
    if (seq == null) return null;
    return seq % 2 == 1 ? 'male' : 'female';
  }

  static String? mask(String? id) {
    if (id == null || id.length < 4) return id;
    return '****${id.substring(id.length - 4)}';
  }

  static bool _isDigit(int codePoint) => codePoint >= 0x30 && codePoint <= 0x39;

  /// 第 7-14 位按 yyyyMMdd 严格解析(2 月 30 日之类不存在的日期返回 null)。
  static DateTime? _parseBirthDate(String id) {
    final digits = id.substring(6, 14);
    if (!RegExp(r'^\d{8}$').hasMatch(digits)) return null;
    final year = int.parse(digits.substring(0, 4));
    final month = int.parse(digits.substring(4, 6));
    final day = int.parse(digits.substring(6, 8));
    final value = DateTime.utc(year, month, day);
    if (value.year != year || value.month != month || value.day != day) {
      return null;
    }
    return value;
  }
}
