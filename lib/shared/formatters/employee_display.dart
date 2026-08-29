/// 员工姓名与工号的统一展示格式。
///
/// 工号存在时固定输出 `姓名(工号)`，括号使用 ASCII 半角字符；工号缺失的
/// 历史/最小权限接口回退为纯姓名，避免空括号。
String formatEmployeeDisplayName(String name, String? employeeCode) {
  final normalizedName = name.trim();
  final normalizedCode = employeeCode?.trim() ?? '';
  if (normalizedCode.isEmpty) return normalizedName;
  final suffix = '($normalizedCode)';
  return normalizedName.endsWith(suffix)
      ? normalizedName
      : '$normalizedName$suffix';
}
