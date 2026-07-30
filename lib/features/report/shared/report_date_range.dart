// 报表日期范围默认值（共享）。
//
// 业务诉求：报表进页默认范围 = 「上月今日 .. 今日」，而不是 2018/2010 至今
// （后者一进来就拉十几年全量，慢且大多无关）。例：今天 2026-07-27 → 起 2026-06-27。
//
// 用日历月回退（DateTime 构造器自动归一化），而非固定天数：月末日（如 03-31）
// 会归一到次月（03-03），符合"前一个月"语义。DatePicker 的可选下限 firstDate 仍保留
// 2010（历史数据要能手选回去），仅默认值收紧。

import '../../../core/utils/china_datetime.dart';

/// 报表默认起始日：今天往前一个日历月（同日）。
DateTime defaultReportFrom() {
  final now = ChinaDateTime.today();
  return DateTime.utc(now.year, now.month - 1, now.day);
}
