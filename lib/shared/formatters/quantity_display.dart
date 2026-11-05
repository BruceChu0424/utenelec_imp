// 数量显示与解析的公共格式化（无业务语义，纯数字排版）。
//
// 供车间内料仓 / 盘点审核等页面共用：十进制原文优先，完整保留有效小数，不自动取位。
import 'exact_decimal.dart';
import '../../core/formatters/exact_number_text.dart';

/// Recorded quantities keep all decimal digits, including values beyond the
/// range in which a double can preserve the document's four decimal places.
String formatExactQtyWithUnit(
  String? value,
  String? unit, {
  bool groupThousands = false,
}) {
  final exact = financeExactDecimal(value);
  if (exact == null) return '';
  final number = exactNumberDisplay(exact, groupThousands: groupThousands)!;
  final suffix = unit?.trim() ?? '';
  return suffix.isEmpty ? number : '$number $suffix';
}

/// Quantity display preserves every finite digit. [maxDecimals] remains a
/// source-compatible hint; it cannot cap or round a recorded quantity.
String formatQty(Object? value, {int maxDecimals = 2}) {
  if (value == null) return '';
  return exactNumberDisplay(value) ?? value.toString();
}

/// 输入框文本 → 数量; 空或非法为 null。
double? parseQty(String text) {
  final raw = text.trim().replaceAll(',', '');
  if (raw.isEmpty) return null;
  return double.tryParse(raw);
}

/// 「数量 + 单位」内联显示的统一口径 (2026-10-10 全站表格改造)。
///
/// 全站表格逐步把独立的「单位」列撤掉、单位直接跟在数量后面 (如 `12 PCS`、
/// `3.5 米`)，本函数是唯一拼装点，保证空值/空单位时只显示数字、不落多余的
/// 空格。排序侧由 MasterDataTableView 的数值容错解析兜底 (会剥掉这里的单位
/// 后缀按数字排序)，页面不必各写一套。
String formatQtyWithUnit(num? value, String? unit, {int? maxDecimals}) {
  final number = formatQty(value, maxDecimals: maxDecimals ?? 4);
  if (number.isEmpty) return '';
  final suffix = unit?.trim() ?? '';
  return suffix.isEmpty ? number : '$number $suffix';
}
