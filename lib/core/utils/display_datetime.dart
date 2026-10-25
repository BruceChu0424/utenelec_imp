/// 全平台业务时间统一按北京时间展示，不跟随设备时区。
///
/// 带显式偏移的时间串按同一真实时刻换算；无偏移值按北京墙上时间
/// 解释。日期/ISO 机器字段继续使用各自标准序列化，不附展示后缀。
library;

import 'china_datetime.dart';

abstract final class DisplayDateTime {
  static String beijing(String? iso, {String fallback = ''}) =>
      ChinaDateTime.formatIsoInstant(iso, fallback: fallback);

  /// [wallTime] 已经是中国墙上时间，不再重复转换。
  static String beijingWall(DateTime wallTime) =>
      ChinaDateTime.formatDateTime(wallTime);

  /// 旧 [local] 参数只为调用兼容保留，业务显示始终为北京时间。
  static String format(
    String? iso, {
    bool local = false,
    String fallback = '',
  }) => beijing(iso, fallback: fallback);

  /// 解析为可比较、可序列化的真实 UTC 时间点。
  /// 北京墙上载体仅用于显示，不能用于与 DateTime.now() 比较。
  static DateTime? instantOf(String? iso) {
    final wallTime = ChinaDateTime.tryParse(iso);
    return wallTime == null ? null : ChinaDateTime.wallTimeToUtc(wallTime);
  }
}
