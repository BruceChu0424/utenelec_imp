// 报表单元格格式化（共享）—— 取代各报表页 private _cell，按列 type 统一格式化。
//
// money/number → 中国大陆千分位格式；bool → 是/否；date → yyyy-MM-dd；其余原样。

import '../../../core/formatters/china_number_format.dart';
import 'report_column.dart';

/// 按 [col.type] 格式化 [row] 中该列的值为展示字符串；空值返回 null。
String? formatReportCell(ReportColumn col, Map<String, dynamic> row) {
  final v = row[col.key];
  if (v == null) return null;
  switch (col.type) {
    case 'money':
    case 'number':
      final n = v is num ? v : num.tryParse('$v');
      return n == null ? '$v' : formatChinaNumber(n);
    case 'int':
      final n = v is num ? v : num.tryParse('$v');
      return n == null ? '$v' : formatChinaNumber(n, decimalDigits: 0);
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
