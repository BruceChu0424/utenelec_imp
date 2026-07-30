/// 中国大陆业务时间工具。
///
/// 中国大陆当前统一使用 UTC+08:00，且没有夏令时。业务日期、预约时间等“墙上时间”
/// 用 UTC [DateTime] 作为无时区载体，确保设备即使误设为其他时区也不会跨日。
abstract final class ChinaDateTime {
  static const utcOffset = Duration(hours: 8);

  /// 当前中国标准时间。返回值的年月日时分秒是中国墙上时间。
  static DateTime now({DateTime? utcNow}) {
    final instant = (utcNow ?? DateTime.now()).toUtc();
    return _wallClock(instant.add(utcOffset));
  }

  /// 当前中国业务日期（00:00）。
  static DateTime today({DateTime? utcNow}) {
    final value = now(utcNow: utcNow);
    return DateTime.utc(value.year, value.month, value.day);
  }

  /// 把一个真实时间点转换为中国墙上时间。
  static DateTime fromInstant(DateTime instant) =>
      _wallClock(instant.toUtc().add(utcOffset));

  /// 把中国墙上时间转换为可提交给后端的 UTC 时间点。
  ///
  /// 只读取 [wallTime] 的年月日时分秒，不使用设备时区。
  static DateTime wallTimeToUtc(DateTime wallTime) {
    return DateTime.utc(
      wallTime.year,
      wallTime.month,
      wallTime.day,
      wallTime.hour,
      wallTime.minute,
      wallTime.second,
      wallTime.millisecond,
      wallTime.microsecond,
    ).subtract(utcOffset);
  }

  /// 创建不受设备时区影响的墙上时间值。
  static DateTime wallTime({
    required int year,
    required int month,
    required int day,
    int hour = 0,
    int minute = 0,
    int second = 0,
  }) => DateTime.utc(year, month, day, hour, minute, second);

  /// 仅保留输入值的墙上时间字段，用于标准化日期/时间选择器返回值。
  static DateTime asWallTime(DateTime value) => _wallClock(value);

  /// 解析后端日期时间。
  ///
  /// 带 `Z`/偏移量的字符串按真实时间点转成中国时间；无偏移量的数据库
  /// `LocalDateTime` 按中国墙上时间保留原字段，避免被设备时区二次换算。
  static DateTime? tryParse(String? value) {
    final raw = value?.trim();
    if (raw == null || raw.isEmpty) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return null;
    return _hasExplicitOffset(raw) ? fromInstant(parsed) : _wallClock(parsed);
  }

  static String formatDate(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  static String formatDateTime(DateTime value) =>
      '${formatDate(value)} '
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';

  static String formatInstant(DateTime instant) =>
      formatDateTime(fromInstant(instant));

  static String formatIsoInstant(String? value, {String fallback = ''}) {
    final parsed = tryParse(value);
    return parsed == null ? fallback : formatDateTime(parsed);
  }

  static bool sameWallMinute(DateTime a, DateTime b) =>
      a.year == b.year &&
      a.month == b.month &&
      a.day == b.day &&
      a.hour == b.hour &&
      a.minute == b.minute;

  static DateTime _wallClock(DateTime value) => DateTime.utc(
    value.year,
    value.month,
    value.day,
    value.hour,
    value.minute,
    value.second,
    value.millisecond,
    value.microsecond,
  );

  static bool _hasExplicitOffset(String value) {
    // 日期中的 "-30" 不是时区；只有带时间部分的 ISO 值才检查尾部偏移。
    if (!value.contains(RegExp(r'[Tt ]'))) return false;
    return RegExp(r'(?:[zZ]|[+-]\d{2}(?::?\d{2})?)$').hasMatch(value);
  }
}
