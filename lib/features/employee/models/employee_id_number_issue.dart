// 员工证件号码问题(服务端 EmployeeIdentityCheck.issueOf 唯一判定，客户端只展示)。
//
// 对应接口字段 idNumberIssue：null 表示不用处理；否则是
// {"kind": "missing"|"invalid"|"unchecked", "reason": "服务端写好的具体原因"}。
// reason 只说位置和长度(如「身份证号应为18位，当前为17位」)，不含号码本身。
// 出现在：员工详情、开号前就绪检查、开号/入职返回的员工资料。

/// 问题种类：决定提醒颜色。校验未通过=红；缺失、未校验=黄。
enum EmployeeIdNumberIssueKind {
  /// 档案里没有证件号码。
  missing('missing'),

  /// 证件类型是身份证，但号码没通过校验。
  invalid('invalid'),

  /// 号码来自历史资料导入，系统还没校验。
  unchecked('unchecked');

  const EmployeeIdNumberIssueKind(this.code);

  final String code;

  /// 未知代码返回 null(服务端与客户端同仓发版，不会出现新代码而客户端不认识)。
  static EmployeeIdNumberIssueKind? fromCode(Object? value) {
    for (final kind in values) {
      if (kind.code == value) return kind;
    }
    return null;
  }
}

class EmployeeIdNumberIssue {
  const EmployeeIdNumberIssue({required this.kind, required this.reason});

  final EmployeeIdNumberIssueKind kind;

  /// 服务端给出的具体原因，原样展示。
  final String reason;

  /// 校验未通过用红色，其余用黄色。
  bool get isError => kind == EmployeeIdNumberIssueKind.invalid;

  /// 解析 idNumberIssue 字段；null、非对象或未知种类都返回 null(不展示提醒)。
  static EmployeeIdNumberIssue? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = EmployeeIdNumberIssueKind.fromCode(json['kind']);
    if (kind == null) return null;
    final reason = json['reason'];
    return EmployeeIdNumberIssue(
      kind: kind,
      reason: reason is String ? reason.trim() : '',
    );
  }
}
