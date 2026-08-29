/// 全平台统一的时间展示格式。
///
/// 默认北京时间：'yyyy-MM-dd HH:mm（北京）'，不再出现 "+08:00" 这类偏移写法。
/// 用户可切换为设备当地时间：'yyyy-MM-dd HH:mm（当地 · 东京 UTC+9）'。
///
/// 解析规则与 [ChinaDateTime.tryParse] 一致：带显式时区偏移的串按真实时间点换算；
/// 无偏移的数据库 LocalDateTime 串按北京墙上时间理解，避免设备时区二次换算。
library;

import 'china_datetime.dart';

abstract final class DisplayDateTime {
  /// 北京时间展示：'yyyy-MM-dd HH:mm（北京）'。解析失败回退 [fallback]。
  static String beijing(String? iso, {String fallback = ''}) {
    final text = ChinaDateTime.formatIsoInstant(iso);
    if (text.isEmpty) return fallback;
    return '$text(北京)';
  }

  /// 北京时间展示（DateTime 入参，[wallOrInstant] 为中国墙上时间）。
  static String beijingWall(DateTime wallTime) =>
      '${ChinaDateTime.formatDateTime(wallTime)}(北京)';

  /// 当前时间按北京时间展示。
  static String beijingNow() => beijingWall(ChinaDateTime.now());

  /// 按展示模式格式化：北京时间或设备当地时间。
  static String format(
    String? iso, {
    bool local = false,
    String fallback = '',
  }) {
    if (!local) return beijing(iso, fallback: fallback);
    final instant = instantOf(iso);
    if (instant == null) return fallback.isEmpty ? (iso ?? '') : fallback;
    final localTime = instant.toLocal();
    return '${_formatLocal(localTime)}(当地 · ${localZoneLabel(localTime)})';
  }

  /// 把后端时间串解析成真实时间点（UTC instant）。
  /// 无偏移串按北京墙上时间换算；解析失败返回 null。
  static DateTime? instantOf(String? iso) {
    final raw = iso?.trim();
    if (raw == null || raw.isEmpty) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return null;
    if (_hasExplicitOffset(raw)) return parsed;
    // 无偏移：字段是北京墙上时间，转成真实 UTC 时间点。
    return ChinaDateTime.wallTimeToUtc(
      DateTime.utc(
        parsed.year,
        parsed.month,
        parsed.day,
        parsed.hour,
        parsed.minute,
        parsed.second,
        parsed.millisecond,
        parsed.microsecond,
      ),
    );
  }

  /// 设备当地的可读时区标签，如 '东京 UTC+9'、'纽约 UTC-4'。
  static String localZoneLabel([DateTime? at]) {
    final time = at ?? DateTime.now();
    final offset = time.timeZoneOffset;
    final city = _offsetCityLabels[offset.inMinutes];
    final utc = _utcOffsetText(offset);
    if (city != null) return '$city $utc';
    final name = time.timeZoneName.trim();
    return name.isEmpty ? utc : '$name $utc';
  }

  static String _formatLocal(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')} '
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';

  static String _utcOffsetText(Duration offset) {
    final sign = offset.isNegative ? '-' : '+';
    final absolute = offset.abs();
    final hours = absolute.inHours;
    final minutes = absolute.inMinutes % 60;
    return minutes == 0
        ? 'UTC$sign$hours'
        : 'UTC$sign$hours:${minutes.toString().padLeft(2, '0')}';
  }

  static bool _hasExplicitOffset(String value) {
    if (!value.contains(RegExp(r'[Tt ]'))) return false;
    return RegExp(r'(?:[zZ]|[+-]\d{2}(?::?\d{2})?)$').hasMatch(value);
  }

  /// 常见 UTC 偏移 → 代表城市（分钟键）。用于"获取在哪个地方"的友好提示。
  static const Map<int, String> _offsetCityLabels = {
    -720: '奥克兰(西十二区)',
    -660: '中途岛',
    -600: '檀香山',
    -540: '安克雷奇',
    -480: '洛杉矶',
    -420: '丹佛',
    -360: '芝加哥',
    -300: '纽约',
    -240: '圣地亚哥',
    -180: '圣保罗',
    -120: '南乔治亚',
    -60: '亚速尔群岛',
    0: '伦敦',
    60: '巴黎',
    120: '开罗',
    180: '莫斯科',
    210: '德黑兰',
    240: '迪拜',
    270: '喀布尔',
    300: '卡拉奇',
    330: '孟买',
    345: '加德满都',
    360: '达卡',
    390: '仰光',
    420: '曼谷',
    480: '上海',
    540: '东京',
    570: '达尔文',
    600: '悉尼',
    660: '所罗门群岛',
    720: '奥克兰',
  };
}
