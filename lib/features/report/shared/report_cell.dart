// 报表单元格格式化（共享）—— 取代各报表页 private _cell，按列 type 统一格式化。
//
// money/number → 中国大陆千分位格式；int/count → 千分位整数；bool → 是/否；date → yyyy-MM-dd；
// weight → 千克值按用户显示单位换算 (ADR-135；行里「<列key>Estimated」为 true 时前缀「≈」，
// 空值仍返回 null——没称不显示成 0)；其余原样。

import '../../../core/formatters/china_number_format.dart';
import '../../../shared/measurement/weight_unit.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../../../shared/formatters/money_display.dart';
import '../../../shared/formatters/quantity_display.dart';
import 'report_column.dart';

/// Future month cells are intentionally empty; missing source facts remain unknown.
bool reportCellIsNotApplicable(ReportColumn col, Map<String, dynamic> row) {
  final fields=row['__notApplicable'];
  if(fields is String&&fields.split(',').map((field)=>field.trim()).contains(col.key)||fields is List&&fields.contains(col.key))return true;
  final match = RegExp(r'^[mr](\d{1,2})$').firstMatch(col.key);
  final months = row['__notApplicableMonths'];
  return match != null &&
      months is List &&
      months.contains(int.parse(match.group(1)!));
}

/// 按 [col.type] 格式化 [row] 中该列的值为展示字符串；空值返回 null。
/// [weightDisplay] 只影响 'weight' 列 (默认按量级自动选单位)。
String? formatReportCell(
  ReportColumn col,
  Map<String, dynamic> row, {
  WeightDisplay weightDisplay = WeightDisplay.auto,
  bool includeUnit = true,
}) {
  if (reportCellIsNotApplicable(col, row)) return '—';
  final v = row[col.key];
  // A masked main value remains masked even if an older response retained Exact.
  if (v == null) return null;
  final numeric = const {'money', 'number', 'int', 'count'}.contains(col.type);
  if (numeric && v is! num && financeExactDecimal(v.toString()) == null) {
    return '$v';
  }
  final unitKey = col.unitKey?.trim();
  final sourceUnit = unitKey != null && unitKey.isNotEmpty
      ? row[unitKey]?.toString()
      : col.unitLabel;
  final retainSourceCurrency = row['__showCurrencyInOriginal'] == true &&
      col.type == 'money' && unitKey == 'currencyCode';
  final unit = sourceUnit == '%' || includeUnit || retainSourceCurrency
      ? sourceUnit
      : null;
  final exact = row['${col.key}Exact'];
  final percentages = row['__percentageKeys'];
  if (unit == '%' || percentages is List && percentages.contains(col.key)) {
    final text = exact is String && financeExactDecimal(exact) != null
        ? exact
        : v.toString();
    return financeExactDecimal(text) == null
        ? text
        : '${financeExactMoneyDisplay(text)}%';
  }
  // Frozen originals store the authoritative decimal in the original field.
  // A separate Exact alias is optional; never route valid decimal text through double.
  final authoritative = exact is String && financeExactDecimal(exact) != null
      ? exact
      : v is String && financeExactDecimal(v) != null
      ? v
      : null;
  if (authoritative != null) {
    if (col.type == 'money') {
      return financeMoneyWithUnitSuffix(authoritative, currencyName: unit);
    }
    if (col.type == 'number' || col.type == 'int' || col.type == 'count') {
      return formatExactQtyWithUnit(authoritative, unit);
    }
  }
  switch (col.type) {
    case 'money':
      if (unit?.trim().isNotEmpty == true) {
        return financeMoneyWithUnitSuffix(v.toString(), currencyName: unit);
      }
      final n = v is num ? v : num.tryParse('$v');
      return n == null ? '$v' : formatChinaNumber(n);
    case 'number':
      if (unit?.trim().isNotEmpty == true) {
        return formatExactQtyWithUnit(v.toString(), unit);
      }
      final n = v is num ? v : num.tryParse('$v');
      return n == null ? '$v' : formatChinaNumber(n);
    case 'int':
    case 'count':
      if (unit?.trim().isNotEmpty == true) {
        return formatExactQtyWithUnit(v.toString(), unit);
      }
      final n = v is num ? v : num.tryParse('$v');
      return n == null ? '$v' : formatChinaNumber(n, decimalDigits: 0);
    case 'weight':
      final raw = authoritative ?? financeExactDecimal(v);
      if (raw == null) return '$v';
      final text = formatWeight(raw, display: weightDisplay);
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
