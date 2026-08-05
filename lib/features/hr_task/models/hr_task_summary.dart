// HR 任务中心 API 模型（对应后端 HrTaskSummary / HrTaskSummary.Item）。
// 全部字段为服务端按「今天」动态计算结果，前端不重算。

/// 单条提醒。days 语义随区块：剩余天数 / 逾期天数 / 周岁 / 满年数 / 已入职天数。
class HrTaskItem {
  const HrTaskItem({
    required this.employeeId,
    required this.code,
    required this.name,
    this.deptName,
    this.positionName,
    this.date,
    required this.days,
    this.note,
  });

  final String employeeId;
  final String code;
  final String name;
  final String? deptName;
  final String? positionName;
  final String? date; // yyyy-MM-dd
  final int days;
  final String? note;

  factory HrTaskItem.fromJson(Map<String, dynamic> json) => HrTaskItem(
    employeeId: json['employeeId'] as String,
    code: json['code'] as String,
    name: json['name'] as String,
    deptName: json['deptName'] as String?,
    positionName: json['positionName'] as String?,
    date: json['date'] as String?,
    days: (json['days'] as num?)?.toInt() ?? 0,
    note: json['note'] as String?,
  );
}

class HrTaskSummary {
  const HrTaskSummary({
    required this.generatedAt,
    required this.probationMonths,
    required this.confirmToday,
    required this.confirmUpcoming,
    required this.confirmOverdue,
    required this.unconfirmedLegacyCount,
    required this.birthdayToday,
    required this.birthdayUpcoming,
    required this.anniversaryToday,
    required this.newHires,
    required this.badgeCount,
  });

  final String generatedAt;
  final int probationMonths;
  final List<HrTaskItem> confirmToday;
  final List<HrTaskItem> confirmUpcoming;
  final List<HrTaskItem> confirmOverdue;
  final int unconfirmedLegacyCount;
  final List<HrTaskItem> birthdayToday;
  final List<HrTaskItem> birthdayUpcoming;
  final List<HrTaskItem> anniversaryToday;
  final List<HrTaskItem> newHires;
  final int badgeCount;

  static List<HrTaskItem> _items(Map<String, dynamic> json, String key) =>
      ((json[key] as List?) ?? const [])
          .map((e) => HrTaskItem.fromJson(e as Map<String, dynamic>))
          .toList();

  factory HrTaskSummary.fromJson(Map<String, dynamic> json) => HrTaskSummary(
    generatedAt: json['generatedAt'] as String? ?? '',
    probationMonths: (json['probationMonths'] as num?)?.toInt() ?? 3,
    confirmToday: _items(json, 'confirmToday'),
    confirmUpcoming: _items(json, 'confirmUpcoming'),
    confirmOverdue: _items(json, 'confirmOverdue'),
    unconfirmedLegacyCount:
        (json['unconfirmedLegacyCount'] as num?)?.toInt() ?? 0,
    birthdayToday: _items(json, 'birthdayToday'),
    birthdayUpcoming: _items(json, 'birthdayUpcoming'),
    anniversaryToday: _items(json, 'anniversaryToday'),
    newHires: _items(json, 'newHires'),
    badgeCount: (json['badgeCount'] as num?)?.toInt() ?? 0,
  );
}
