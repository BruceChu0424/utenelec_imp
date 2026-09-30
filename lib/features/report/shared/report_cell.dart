// 报表单元格格式化（共享）—— 取代各报表页 private _cell，按列 type 统一格式化。
//
// money/number → 中国大陆千分位格式；int/count → 千分位整数；bool → 是/否；date → yyyy-MM-dd；
// weight → 千克值按用户显示单位换算 (ADR-135；行里「<列key>Estimated」为 true 时前缀「≈」，
// 空值仍返回 null——没称不显示成 0)；其余原样。

import '../../../core/formatters/china_number_format.dart';
import '../../../shared/measurement/weight_unit.dart';
import '../../../shared/formatters/exact_decimal.dart';
import 'report_column.dart';

/// 按 [col.type] 格式化 [row] 中该列的值为展示字符串；空值返回 null。
/// [weightDisplay] 只影响 'weight' 列 (默认按量级自动选单位)。
String? formatReportCell(
  ReportColumn col,
  Map<String, dynamic> row, {
  WeightDisplay weightDisplay = WeightDisplay.auto,
}) {
  final exact = row['${col.key}Exact'];
  if (exact is String && financeExactDecimal(exact) != null) {
    if (col.type == 'money') return financeExactMoneyDisplay(exact);
    if (col.type == 'number' || col.type == 'int' || col.type == 'count') {
      return financeExactTrimmed(exact);
    }
  }
  final v = row[col.key];
  if (v == null) return null;
  switch (col.type) {
    case 'money':
    case 'number':
      final n = v is num ? v : num.tryParse('$v');
      return n == null ? '$v' : formatChinaNumber(n);
    case 'int':
    case 'count':
      final n = v is num ? v : num.tryParse('$v');
      return n == null ? '$v' : formatChinaNumber(n, decimalDigits: 0);
    case 'weight':
      final n = v is num ? v : num.tryParse('$v');
      if (n == null) return '$v';
      final text = formatWeight(n.toDouble(), display: weightDisplay);
      return row['${col.key}Estimated'] == true ? '≈$text' : text;
    case 'bool':
      final b = v is bool ? v : '$v' == 'true';
      return b ? '是' : '否';
    case 'date':
      final s = '$v';
      return s.length >= 10 ? s.substring(0, 10) : s;
    default:
      return '$v';
  }
}
