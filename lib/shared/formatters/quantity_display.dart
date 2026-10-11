// 数量显示与解析的公共格式化（无业务语义，纯数字排版）。
//
// 供车间内料仓 / 盘点审核等页面共用：最多 N 位小数、去掉末尾 0、-0 归 0。
/// 数量显示: 最多 [maxDecimals] 位小数, 去掉末尾的 0。
String formatQty(num? value, {int maxDecimals = 2}) {
  if (value == null) return '';
  var text = value.toStringAsFixed(maxDecimals);
  if (text.contains('.')) {
    text = text.replaceFirst(RegExp(r'0+$'), '');
    if (text.endsWith('.')) text = text.substring(0, text.length - 1);
  }
  return text == '-0' ? '0' : text;
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
String formatQtyWithUnit(
  num? value,
  String? unit, {
  int maxDecimals = 3,
}) {
  final number = formatQty(value, maxDecimals: maxDecimals);
  if (number.isEmpty) return '';
  final suffix = unit?.trim() ?? '';
  return suffix.isEmpty ? number : '$number $suffix';
}
