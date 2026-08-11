// 工龄动态计算：只依赖入职日期 + 当前日期，每天都变，不落库、不需要后端字段。
// 口径与 PostgreSQL age() 一致：整年 + 整月（不满一个月的日子舍去）。
// 日期基准用 ChinaDateTime（中国墙上时间，不受设备时区误设影响）。
// 用法：workYearsText(l10n, employee.hireDate)
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/utils/china_datetime.dart';

/// 返回「X 年 Y 个月」/「Y 个月」/「不足 1 个月」；无法解析时返回 '—'。
String workYearsText(AppLocalizations l10n, String? hireDate) {
  if (hireDate == null || hireDate.isEmpty) return '—';
  final hire = DateTime.tryParse(hireDate);
  if (hire == null) return '—';
  final today = ChinaDateTime.today();

  var years = today.year - hire.year;
  var months = today.month - hire.month;
  if (today.day < hire.day) {
    months -= 1;
  }
  if (months < 0) {
    years -= 1;
    months += 12;
  }
  if (years < 0) return '—'; // 入职日期在未来，视为数据异常
  if (years == 0 && months == 0) return l10n.employeeWorkYearsUnderOneMonth;
  if (years == 0) return l10n.employeeWorkYearsMonths(months);
  return l10n.employeeWorkYearsYandM(years, months);
}
