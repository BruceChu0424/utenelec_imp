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

/// Account and employment are independent facts. Missing fields from older or
/// privacy-limited APIs must never be treated as an unprovisioned account.
String employeeAccountStatusLabel(String? status) => switch (status?.trim()) {
  'notProvisioned' => '未开通',
  'active' => '已开通',
  'locked' => '锁定',
  'disabled' => '停用',
  'deleted' => '已删除',
  'blocked' => '已封禁',
  'notApplicable' => '不适用',
  null || '' => '未提供',
  _ => '未知状态',
};

String employeeEmploymentStatusLabel(String? status) =>
    switch (status?.trim()) {
      'active' => '在职',
      'probation' => '试用',
      'onLeave' => '休假',
      'resigned' => '离职',
      'notApplicable' => '不适用',
      null || '' => '未提供',
      _ => '未知状态',
    };
