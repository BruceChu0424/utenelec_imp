// HR 任务中心 API 模型（对应后端 HrTaskSummary / HrTaskSummary.Item）。
// 全部字段为服务端按「今天」动态计算结果，前端不重算。

/// 单条提醒。days 语义随区块：剩余天数 / 逾期天数 / 周岁 / 满年数 / 已入职天数。
/// 软认领（ADR-021）：任务不隐藏，claimedByName 非空显示「XXX 处理中」。
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
    this.claimedByName,
    this.claimedByMe = false,
    this.claimLeaseUntil,
  });

  final String employeeId;
  final String code;
  final String name;
  final String? deptName;
  final String? positionName;
  final String? date; // yyyy-MM-dd
  final int days;
  final String? note;

  /// 认领人姓名（null = 未认领）。
  final String? claimedByName;

  /// 是否我认领（本人可继续/释放；他人快捷操作禁用）。
  final bool claimedByMe;

  /// 认领租约到期时间（ISO8601）。
  final String? claimLeaseUntil;

  /// 被他人认领处理中（非我）。
  bool get claimedByOther => claimedByName != null && !claimedByMe;

  factory HrTaskItem.fromJson(Map<String, dynamic> json) => HrTaskItem(
    employeeId: json['employeeId'] as String,
    code: json['code'] as String,
    name: json['name'] as String,
    deptName: json['deptName'] as String?,
    positionName: json['positionName'] as String?,
    date: json['date'] as String?,
    days: (json['days'] as num?)?.toInt() ?? 0,
    note: json['note'] as String?,
    claimedByName: json['claimedByName'] as String?,
    claimedByMe: json['claimedByMe'] as bool? ?? false,
    claimLeaseUntil: json['claimLeaseUntil'] as String?,
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
